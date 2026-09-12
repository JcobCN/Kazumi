import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image;
import 'package:kazumi/services/logging/logger.dart';
import 'package:onnxruntime/onnxruntime.dart';

/// Captcha OCR backed by the ddddocr model (MIT) running through the ONNX
/// Runtime Flutter plugin (C++ inference engine, dart:ffi bindings).
///
/// ddddocr is trained specifically on distorted captcha glyphs, so it handles
/// twisted/overlapping characters that defeat general-purpose print-text OCR
/// models.
class CaptchaOcrService {
  static const String _modelPath = 'assets/ocr/ddddocr.onnx';
  static const String _charsetPath = 'assets/ocr/ddddocr_charset.json';

  // Input: NCHW float [1,1,64,W], grayscale, x/255 in [0,1]. Height is fixed
  // to 64; width preserves the aspect ratio (truncated, like ddddocr).
  static const int _inputHeight = 64;

  // Output: [26,1,8210] CTC logits over the charset; index 0 is blank.
  static bool get isSupported => !kIsWeb;

  static OrtEnv? _env;
  static OrtSession? _session;
  static List<String>? _charset;
  static Future<void>? _initFuture;
  static Future<void> _inferenceLock = Future.value();

  /// Serializes all inference. The onnxruntime plugin's runAsync
  /// implementations share native state per session, so concurrent calls can
  /// interleave; a simple chained future keeps them strictly ordered.
  static Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _inferenceLock.then((_) => action());
    _inferenceLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  static Future<void> _ensureInit() async {
    try {
      return _initFuture ??= _init();
    } catch (_) {
      _initFuture = null;
      rethrow;
    }
  }

  static Future<void> _init() async {
    _env ??= OrtEnv.instance;
    _env!.init();

    final modelBytes = (await rootBundle.load(_modelPath)).buffer.asUint8List();
    final charsetRaw = await rootBundle.loadString(_charsetPath);
    final decoded = jsonDecode(charsetRaw);
    if (decoded is! List) {
      throw StateError('ddddocr charset is not a JSON list');
    }
    _charset = decoded.map((e) => e.toString()).toList();

    _session = OrtSession.fromBuffer(modelBytes, OrtSessionOptions());
    KazumiLogger().i(
        '[CaptchaOcr] ddddocr loaded (dict=${_charset!.length}, '
        'model=${modelBytes.length ~/ 1024}KB)');
  }

  /// Recognize captcha text from a base64 data URL. Returns the decoded text
  /// (whitespace stripped) or null when nothing was recognized.
  static Future<String?> recognizeCaptcha(String base64DataUrl) {
    return _serialized(() => _recognizeCaptcha(base64DataUrl));
  }

  static Future<String?> _recognizeCaptcha(String base64DataUrl) async {
    try {
      final base64Str = base64DataUrl.contains(',')
          ? base64DataUrl.split(',').last
          : base64DataUrl;
      final imageBytes = base64Decode(base64Str.replaceAll(RegExp(r'\s'), ''));
      final decoded = image.decodeImage(imageBytes);
      if (decoded == null) return null;

      await _ensureInit();

      final text = await _classify(decoded);
      KazumiLogger().i('[CaptchaOcr] ddddocr result: $text');
      return text.isEmpty ? null : text;
    } catch (e, st) {
      KazumiLogger().w('[CaptchaOcr] OCR failed: $e\n$st');
      return null;
    }
  }

  static Future<String> _classify(image.Image img) async {
    final session = _session;
    final charset = _charset;
    if (session == null || charset == null) return '';

    final w = (img.width * (_inputHeight / img.height)).toInt();
    if (w < 1) return '';
    final resized = image.copyResize(
      img,
      width: w,
      height: _inputHeight,
      interpolation: image.Interpolation.linear,
    );

    // ITU-R 601-2 luma, matching PIL's convert('L').
    final out = Float32List(w * _inputHeight);
    var idx = 0;
    for (var y = 0; y < _inputHeight; y++) {
      for (var x = 0; x < w; x++) {
        final p = resized.getPixel(x, y);
        final l = (p.r * 299 + p.g * 587 + p.b * 114) / 1000.0;
        out[idx++] = l / 255.0;
      }
    }

    final inputOrt = OrtValueTensor.createTensorWithDataList(
      out,
      [1, 1, _inputHeight, w],
    );
    final runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = await session.runAsync(runOptions, {'input1': inputOrt});
      final value =
          outputs != null && outputs.isNotEmpty ? outputs.first?.value : null;
      if (value is! List || value.isEmpty) return '';
      return _decode(value, charset);
    } finally {
      for (final o in outputs ?? const <OrtValue?>[]) {
        o?.release();
      }
      inputOrt.release();
      runOptions.release();
    }
  }

  /// Decode strategy: captcha charsets are digits in the vast majority of
  /// cases, and letters in the unrestricted decode are usually font
  /// confusions (o/0, i/1, u/0, ...). When the unrestricted result contains
  /// any non-digit, re-decode with the per-step argmax restricted to digits
  /// (keeping the blank class so CTC collapsing still applies); fall back to
  /// the unrestricted result when that yields nothing.
  static String _decode(List output, List<String> charset) {
    final free = _ctcDecodeAlnum(output, charset);
    if (free.isEmpty) return free;
    final hasNonDigit = free.codeUnits.any((c) => c < 0x30 || c > 0x39);
    if (!hasNonDigit) return free;
    final digits = _ctcDecodeRestricted(output, charset, digitsOnly: true);
    return digits.isEmpty ? free : digits;
  }

  /// CTC greedy decode with the per-step argmax restricted to a charset
  /// subset (blank + digits when [digitsOnly]).
  static String _ctcDecodeRestricted(
    List output,
    List<String> charset, {
    required bool digitsOnly,
  }) {
    final sb = StringBuffer();
    var prevIdx = -1;
    for (var t = 0; t < output.length; t++) {
      var step = output[t];
      if (step is List && step.length == 1 && step[0] is List) {
        step = step[0];
      }
      if (step is! List || step.isEmpty) continue;

      var bestIdx = 0;
      var bestVal = double.negativeInfinity;
      final classes = step.length < charset.length ? step.length : charset.length;
      for (var c = 0; c < classes; c++) {
        if (c != 0 && !_isDigit(charset[c])) continue;
        final v = step[c];
        if (v is! num) continue;
        final d = v.toDouble();
        if (d > bestVal) {
          bestVal = d;
          bestIdx = c;
        }
      }

      if (bestIdx <= 0) {
        prevIdx = -1;
        continue;
      }
      if (bestIdx == prevIdx) continue; // collapse repeats
      prevIdx = bestIdx;
      sb.write(charset[bestIdx]);
    }
    return sb.toString();
  }

  /// CTC greedy decode over [seqlen,1,classes] logits. When a step's best
  /// character is outside [0-9a-zA-Z], fall back to that step's best
  /// alphanumeric character instead of dropping the position.
  static String _ctcDecodeAlnum(List output, List<String> charset) {
    final sb = StringBuffer();
    var prevIdx = -1;
    for (var t = 0; t < output.length; t++) {
      var step = output[t];
      // [seqlen,1,classes] nests one batch row inside each step.
      if (step is List && step.length == 1 && step[0] is List) {
        step = step[0];
      }
      if (step is! List || step.isEmpty) continue;

      var bestIdx = -1;
      var bestVal = double.negativeInfinity;
      var bestAlnumIdx = -1;
      var bestAlnumVal = double.negativeInfinity;
      final classes = step.length < charset.length ? step.length : charset.length;
      for (var c = 0; c < classes; c++) {
        final v = step[c];
        if (v is! num) continue;
        final d = v.toDouble();
        if (d > bestVal) {
          bestVal = d;
          bestIdx = c;
        }
        if (d > bestAlnumVal && _isAlnum(charset[c])) {
          bestAlnumVal = d;
          bestAlnumIdx = c;
        }
      }

      if (bestIdx <= 0) {
        prevIdx = -1;
        continue;
      }
      if (bestIdx == prevIdx) continue; // collapse repeats
      prevIdx = bestIdx;

      final ch = charset[bestIdx];
      if (_isAlnum(ch)) {
        sb.write(ch);
      } else if (bestAlnumIdx > 0) {
        sb.write(charset[bestAlnumIdx]);
      }
    }
    return sb.toString();
  }

  static bool _isDigit(String c) {
    if (c.length != 1) return false;
    final code = c.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }

  static bool _isAlnum(String c) {
    if (c.length != 1) return false;
    final code = c.codeUnitAt(0);
    return (code >= 0x30 && code <= 0x39) || // 0-9
        (code >= 0x41 && code <= 0x5A) || // A-Z
        (code >= 0x61 && code <= 0x7A); // a-z
  }
}

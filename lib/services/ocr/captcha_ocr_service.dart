import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as image;
import 'package:kazumi/services/logging/logger.dart';
import 'package:onnxruntime/onnxruntime.dart';

/// Captcha OCR backed by Baidu PaddleOCR PP-OCRv6 tiny models running through
/// the ONNX Runtime Flutter plugin (C++ inference engine, dart:ffi bindings).
class CaptchaOcrService {
  static const String _detModelPath = 'assets/ocr/det.onnx';
  static const String _recModelPath = 'assets/ocr/rec.onnx';
  static const String _dictPath = 'assets/ocr/ppocrv6_tiny_dict.txt';

  // det: PP-OCRv6 tiny det (DBNet). Input NCHW float [N,3,H,W], normalized
  // with ImageNet mean/std after scaling to [0,1]. Long side limited to 736.
  static const int _detLimitSideLen = 736;
  static const double _detBoxThresh = 0.4;
  static const double _detUnclipRatio = 1.5;

  // rec: PP-OCRv6 tiny rec (SVTR + CTC). Input NCHW float [N,3,48,W],
  // normalized to [-1,1] as (x/255 - 0.5)/0.5, padded to a multiple of 16.
  static const int _recHeight = 48;
  static const int _recMaxWidth = 320;

  static bool get isSupported => true;

  static OrtEnv? _env;
  static OrtSession? _detSession;
  static OrtSession? _recSession;
  static List<String>? _dict;
  static Future<void>? _initFuture;

  static Future<void> _ensureInit() async {
    _initFuture ??= _init();
    return _initFuture;
  }

  static Object? _firstOutputValue(List<OrtValue?>? outputs) {
    if (outputs == null || outputs.isEmpty) return null;
    final first = outputs.firstWhere((o) => o != null, orElse: () => null);
    return first?.value;
  }

  static Future<void> _init() async {
    _env ??= OrtEnv.instance;
    _env!.init();

    final detBytes = (await rootBundle.load(_detModelPath)).buffer.asUint8List();
    final recBytes = (await rootBundle.load(_recModelPath)).buffer.asUint8List();
    final dictRaw = await rootBundle.loadString(_dictPath);
    _dict = dictRaw.split('\n').where((s) => s.isNotEmpty).toList();

    _detSession = OrtSession.fromBuffer(detBytes, OrtSessionOptions());
    _recSession = OrtSession.fromBuffer(recBytes, OrtSessionOptions());
    KazumiLogger().i(
        '[CaptchaOcr] PP-OCRv6 tiny loaded (dict=${_dict!.length}, '
        'det=${detBytes.length ~/ 1024}KB, rec=${recBytes.length ~/ 1024}KB)');
  }

  /// Recognize captcha text from a base64 data URL. Returns the decoded text
  /// (whitespace stripped) or null when nothing was recognized.
  static Future<String?> recognizeCaptcha(String base64DataUrl) async {
    try {
      final base64Str = base64DataUrl.contains(',')
          ? base64DataUrl.split(',').last
          : base64DataUrl;
      final imageBytes = base64Decode(base64Str.replaceAll(RegExp(r'\s'), ''));
      final decoded = image.decodeImage(imageBytes);
      if (decoded == null) return null;

      await _ensureInit();

      final boxes = await _detectText(decoded);
      if (boxes.isEmpty) {
        KazumiLogger().w('[CaptchaOcr] No text region detected');
        return null;
      }

      final results = <String>[];
      for (final box in boxes) {
        final text = await _recognizeLine(decoded, box);
        if (text.isNotEmpty) results.add(text);
      }

      final joined = results.join().replaceAll(RegExp(r'\s+'), '').trim();
      KazumiLogger().i('[CaptchaOcr] PP-OCRv6 result: $joined');
      return joined.isEmpty ? null : joined;
    } catch (e, st) {
      KazumiLogger().w('[CaptchaOcr] OCR failed: $e\n$st');
      return null;
    }
  }

  static Future<List<Box>> _detectText(image.Image img) async {
    final detSession = _detSession;
    if (detSession == null) return const [];

    final (resized, ratioW, ratioH) = _resizeDet(img);
    final tensor = _imageToDetNchw(resized);

    final inputShape = [1, 3, resized.height, resized.width];
    final inputOrt =
        OrtValueTensor.createTensorWithDataList(tensor, inputShape);
    final runOptions = OrtRunOptions();
    try {
      final outputs = await detSession.runAsync(runOptions, {'x': inputOrt});
      final det = _firstOutputValue(outputs);
      // reshape[1,1,H,W] => det[0][0] is HxW probability map.
      final probMap = det is List && det.isNotEmpty && det[0] is List
          ? det[0][0]
          : null;
      if (probMap is! List || probMap.isEmpty) return const [];

      final mask = _probabilityToMask(probMap, resized.width, resized.height);
      final boxes = _findTextBoxes(mask);
      return boxes
          .map((b) => Box(
                x1: b.x1 / ratioW,
                y1: b.y1 / ratioH,
                x2: b.x2 / ratioW,
                y2: b.y2 / ratioH,
              ))
          .toList();
    } finally {
      inputOrt.release();
      runOptions.release();
    }
  }

  static (image.Image, double, double) _resizeDet(image.Image img) {
    final w = img.width;
    final h = img.height;
    final scale = _detLimitSideLen / math.max(w, h);
    final resizeW = (w * scale).round();
    final resizeH = (h * scale).round();
    final resized = image.copyResize(
      img,
      width: resizeW,
      height: resizeH,
      interpolation: image.Interpolation.linear,
    );
    return (resized, w / resizeW, h / resizeH);
  }

  /// DBNet preprocess: scale to [0,1] then ImageNet normalization, NCHW.
  static Float32List _imageToDetNchw(image.Image img) {
    const mean = [0.485, 0.456, 0.406];
    const std = [0.229, 0.224, 0.225];
    final w = img.width;
    final h = img.height;
    final out = Float32List(3 * h * w);
    var idx = 0;
    final data = img.getBytes(order: image.ChannelOrder.rgba);
    for (var y = 0; y < h; y++) {
      var row = y * w * 4;
      for (var x = 0; x < w; x++) {
        out[idx] = (data[row] / 255.0 - mean[0]) / std[0];
        out[idx + h * w] = (data[row + 1] / 255.0 - mean[1]) / std[1];
        out[idx + 2 * h * w] = (data[row + 2] / 255.0 - mean[2]) / std[2];
        idx++;
        row += 4;
      }
    }
    return out;
  }

  /// Rec preprocess: (x/255 - 0.5)/0.5 -> [-1,1], NCHW.
  static Float32List _imageToRecNchw(image.Image img) {
    final w = img.width;
    final h = img.height;
    final out = Float32List(3 * h * w);
    var idx = 0;
    final data = img.getBytes(order: image.ChannelOrder.rgba);
    for (var y = 0; y < h; y++) {
      var row = y * w * 4;
      for (var x = 0; x < w; x++) {
        out[idx] = (data[row] / 255.0 - 0.5) / 0.5;
        out[idx + h * w] = (data[row + 1] / 255.0 - 0.5) / 0.5;
        out[idx + 2 * h * w] = (data[row + 2] / 255.0 - 0.5) / 0.5;
        idx++;
        row += 4;
      }
    }
    return out;
  }

  /// det output is [1,1,H,W] flattened into a List<List<double>> by the
  /// plugin's reshape; flatten and index in H*W order.
  static List<List<double>> _probabilityToMask(
      List probMap, int width, int height) {
    final flat = <double>[];
    void walk(List list) {
      for (final e in list) {
        if (e is List) {
          walk(e);
        } else if (e is num) {
          flat.add(e.toDouble());
        }
      }
    }

    walk(probMap);
    if (flat.length < width * height) return const [];
    return List.generate(
      height,
      (y) => List.generate(width, (x) => flat[y * width + x]),
      growable: false,
    );
  }

  static List<_BoxQuad> _findTextBoxes(List<List<double>> mask) {
    final height = mask.length;
    final width = mask[0].length;
    final visited =
        List.generate(height, (_) => List.filled(width, false), growable: false);
    final boxes = <_BoxQuad>[];

    final stack = <(int, int)>[];
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (visited[y][x] || mask[y][x] <= _detBoxThresh) continue;
        visited[y][x] = true;
        stack.add((x, y));
        var minX = x, maxX = x, minY = y, maxY = y;
        while (stack.isNotEmpty) {
          final (cx, cy) = stack.removeLast();
          if (cx < minX) minX = cx;
          if (cx > maxX) maxX = cx;
          if (cy < minY) minY = cy;
          if (cy > maxY) maxY = cy;
          for (final (dx, dy) in const [
            (-1, 0), (1, 0), (0, -1), (0, 1),
            (-1, -1), (-1, 1), (1, -1), (1, 1),
          ]) {
            final nx = cx + dx;
            final ny = cy + dy;
            if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
            if (visited[ny][nx] || mask[ny][nx] <= _detBoxThresh) continue;
            visited[ny][nx] = true;
            stack.add((nx, ny));
          }
        }
        final boxW = (maxX - minX + 1).toDouble();
        final boxH = (maxY - minY + 1).toDouble();
        if (boxW < 2 || boxH < 2) continue;
        // Rough DBNet unclip: expand the axis-aligned box by the unclip ratio.
        final padX = (boxW * (_detUnclipRatio - 1) / 2).clamp(1.0, boxW);
        final padY = (boxH * (_detUnclipRatio - 1) / 2).clamp(1.0, boxH);
        boxes.add(_BoxQuad(
          x1: math.max(0, minX - padX),
          y1: math.max(0, minY - padY),
          x2: math.min(width - 1, maxX + padX),
          y2: math.min(height - 1, maxY + padY),
        ));
      }
    }
    // Sort top-to-bottom then left-to-right for reading order.
    boxes.sort((a, b) {
      final byY = a.y1.compareTo(b.y1);
      return byY != 0 ? byY : a.x1.compareTo(b.x1);
    });
    return boxes;
  }

  static Future<String> _recognizeLine(image.Image img, Box box) async {
    final recSession = _recSession;
    final dict = _dict;
    if (recSession == null || dict == null) return '';

    final crop = _cropBox(img, box);
    if (crop == null) return '';

    // resize_norm_img_chinese: keep aspect ratio, height fixed to 48, width
    // limited to 320.
    final h = crop.height;
    final w = crop.width;
    final ratio = w / h;
    final maxRatio = _recMaxWidth / _recHeight;
    int resizeW;
    if (ratio >= maxRatio) {
      resizeW = _recMaxWidth;
    } else {
      resizeW = (_recHeight * ratio).ceil();
    }
    final resized = image.copyResize(
      crop,
      width: resizeW,
      height: _recHeight,
      interpolation: image.Interpolation.linear,
    );

    // Pad width to a multiple of 16 with black (0) as PaddleOCR does.
    final paddedW = ((resizeW + 15) ~/ 16) * 16;
    final tensorInput = paddedW == resizeW
        ? resized
        : image.copyExpandCanvas(
            resized,
            newWidth: paddedW,
            newHeight: _recHeight,
            position: image.ExpandCanvasPosition.topLeft,
            backgroundColor: image.ColorRgb8(0, 0, 0),
          );

    final tensor = _imageToRecNchw(tensorInput);
    final inputShape = [1, 3, _recHeight, paddedW];
    final inputOrt =
        OrtValueTensor.createTensorWithDataList(tensor, inputShape);
    final runOptions = OrtRunOptions();
    try {
      final outputs = await recSession.runAsync(runOptions, {'x': inputOrt});
      final rec = _firstOutputValue(outputs);
      // reshape[1, seq_len, classes] => rec[0] is List<List<double>>.
      if (rec is! List || rec.isEmpty || rec[0] is! List) return '';
      return _ctcDecode(rec[0], dict);
    } finally {
      inputOrt.release();
      runOptions.release();
    }
  }

  static image.Image? _cropBox(image.Image img, Box box) {
    final x1 = box.x1.round().clamp(0, img.width - 1);
    final y1 = box.y1.round().clamp(0, img.height - 1);
    final x2 = box.x2.round().clamp(x1, img.width - 1);
    final y2 = box.y2.round().clamp(y1, img.height - 1);
    final w = x2 - x1 + 1;
    final h = y2 - y1 + 1;
    if (w <= 0 || h <= 0) return null;
    return image.copyCrop(
      img,
      x: x1,
      y: y1,
      width: w,
      height: h,
    );
  }

  /// CTC greedy decode. Model output classes = ["blank"] + character_dict
  /// (with trailing space), so class 0 is blank and class k maps to dict[k-1].
  static String _ctcDecode(List logits, List<String> dict) {
    final classes = logits.isNotEmpty && logits[0] is List
        ? (logits[0] as List).length
        : 0;
    if (classes == 0) return '';

    final sb = StringBuffer();
    var prevIdx = -1;
    for (var t = 0; t < logits.length; t++) {
      final row = logits[t];
      if (row is! List || row.isEmpty) continue;
      var maxIdx = -1;
      var maxVal = double.negativeInfinity;
      for (var c = 0; c < row.length; c++) {
        final v = row[c];
        if (v is num && v.toDouble() > maxVal) {
          maxVal = v.toDouble();
          maxIdx = c;
        }
      }
      if (maxIdx <= 0) {
        prevIdx = -1;
        continue;
      }
      if (maxIdx == prevIdx) continue; // collapse repeats
      prevIdx = maxIdx;
      final charIdx = maxIdx - 1;
      if (charIdx >= 0 && charIdx < dict.length) {
        sb.write(dict[charIdx]);
      }
    }
    return sb.toString();
  }
}

class Box {
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  const Box({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });
}

class _BoxQuad {
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  const _BoxQuad({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });
}

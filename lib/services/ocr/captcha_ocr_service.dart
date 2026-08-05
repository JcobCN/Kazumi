import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:path_provider/path_provider.dart';

class CaptchaOcrService {
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  static Future<String?> recognizeCaptcha(String base64DataUrl) async {
    if (!isSupported) return null;

    File? tempFile;
    try {
      final base64Str = base64DataUrl.contains(',')
          ? base64DataUrl.split(',').last
          : base64DataUrl;
      final imageBytes = base64Decode(
        base64Str.replaceAll(RegExp(r'\s'), ''),
      );

      final tempDir = await getTemporaryDirectory();
      tempFile = File('${tempDir.path}/captcha_ocr.png');
      await tempFile.writeAsBytes(Uint8List.fromList(imageBytes));

      final inputImage = InputImage.fromFile(tempFile);
      final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
      try {
        final result = await recognizer.processImage(inputImage);
        final text = result.text.replaceAll(RegExp(r'\s+'), '').trim();
        KazumiLogger().i('[CaptchaOcr] Recognized: $text');
        return text.isEmpty ? null : text;
      } finally {
        recognizer.close();
      }
    } catch (e, st) {
      KazumiLogger().w('[CaptchaOcr] OCR failed: $e\n$st');
      return null;
    } finally {
      try {
        await tempFile?.delete();
      } catch (_) {}
    }
  }
}

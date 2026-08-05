# google_mlkit_text_recognition only bundles a subset of language models.
# The plugin's initialize() references all four TextRecognizerOptions classes,
# but we only ever construct a Chinese recognizer. Suppress R8 missing-class
# errors for the languages we do not ship, avoiding the other language AARs
# and keeping the APK lean.
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Keep the Chinese recognizer options reachable via reflection in the plugin.
-keep class com.google.mlkit.vision.text.chinese.** { *; }

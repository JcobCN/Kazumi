# onnxruntime plugin uses dart:ffi with a native .so built from the ONNX
# Runtime C/C++ library. It exposes no Java/Kotlin reflection surface, so no
# -keep rules are required for R8. Shrinking the Dart/Java layer is safe.

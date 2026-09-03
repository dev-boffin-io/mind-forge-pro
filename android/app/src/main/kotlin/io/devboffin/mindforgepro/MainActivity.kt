package io.devboffin.mindforgepro

import io.flutter.embedding.android.FlutterActivity

// The custom native_libs MethodChannel used with llama_cpp_dart 0.2.x (to
// resolve an absolute path to our manually-built libllama.so) is gone: the
// 0.9.x line ships its native library in a proper Android AAR, and its own
// LlamaLibrary.load() handles Android resolution internally — a bare
// "libllama.so" is the documented, expected libraryPath value.
class MainActivity : FlutterActivity()

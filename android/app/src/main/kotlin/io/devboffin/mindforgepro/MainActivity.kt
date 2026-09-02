package io.devboffin.mindforgepro

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val nativeLibsChannel = "mind_forge_pro/native_libs"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nativeLibsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "nativeLibraryDir") {
                    // Dart FFI's DynamicLibrary.open() calls dlopen() directly,
                    // which — unlike System.loadLibrary() — does not
                    // automatically search the app's bundled jniLibs
                    // directory on every device. Handing Dart the absolute
                    // path avoids relying on that resolution at all.
                    result.success(applicationInfo.nativeLibraryDir)
                } else {
                    result.notImplemented()
                }
            }
    }
}

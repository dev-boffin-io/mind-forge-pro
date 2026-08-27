# Mind-Forge Pro — release ProGuard/R8 rules
# Flutter's own default rules (flutter_embedding, plugin registrant, etc.)
# are appended automatically by the Flutter Gradle plugin — these only
# cover the extra native/FFI and reflection-sensitive pieces this app adds.

# --- llama_cpp_dart / native FFI ---
# Dart FFI calls into the native llama.cpp .so by symbol name at runtime,
# not through a Java/Kotlin binding class, so there is normally nothing
# Java-side to keep here — but if the plugin ships a thin JNI/Kotlin shim,
# keep it intact rather than risk R8 renaming something native code expects.
-keep class com.llama_cpp_dart.** { *; }
-dontwarn com.llama_cpp_dart.**

# --- sqflite ---
-keep class com.tekartik.sqflite.** { *; }

# --- shelf / shelf_router (pure Dart, but keep isolate/HTTP-related JNI glue) ---
-keep class io.flutter.plugins.** { *; }

# --- file_picker ---
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# --- permission_handler ---
-keep class com.baseflow.permissionhandler.** { *; }

# General safety net: don't strip anything annotated Keep, and keep
# native method signatures so JNI/FFI symbol lookups never break.
-keepclasseswithmembernames class * {
    native <methods>;
}
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

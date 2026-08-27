# Mind-Forge Pro

An offline, on-device "second brain" AI agent for Android. No Termux, no
external Ollama server — the app embeds llama.cpp natively via Dart FFI and
serves itself over a local HTTP API.

## How it works

- **Chat** — talk to a locally-loaded `.gguf` model. Every turn is grounded
  with a lightweight TF-IDF retrieval pass over your own stored notes
  (`lib/memory_agent.dart`) before it reaches the model.
- **Memory DB** — browse, inspect, and delete anything the app has
  remembered (SQLite, on-device only).
- **Server Config** — pick a `.gguf` file from local storage and start a
  local API server (`http://127.0.0.1:<port>/api/generate`) that any other
  app or script on the device can call.

## Architecture

| Layer | Tech |
|---|---|
| UI | Flutter (Material 3) |
| Inference | [llama_cpp_dart](https://pub.dev/packages/llama_cpp_dart), off the UI thread via `LlamaParent`/`LlamaScope` |
| Local server | `shelf` + `shelf_router` |
| Memory / RAG | `sqflite` + a pure-Dart TF-IDF keyword ranker |
| Native actions | a `MethodChannel` the model can trigger via `<ACTION: X>` tags |

## Building

CI (`.github/workflows/build-apk.yml`) does everything needed for a
sideloadable release APK — no production keystore required:

1. Compiles `libllama.so` (+ its `libggml*.so` dependencies) from the
   `llama.cpp` source via the Android NDK, since `llama_cpp_dart` 0.2.x is a
   pure FFI binding and ships no prebuilt binary itself. The result lands in
   `android/app/src/main/jniLibs/arm64-v8a/`.
2. Runs `flutter build apk --release --target-platform android-arm64` with
   R8/ProGuard shrinking and native debug-symbol stripping enabled
   (`android/app/build.gradle`).
3. Signs the release build with the standard Android **debug** keystore,
   cached across runs so every build shares the same signing key — that's
   what lets you install an updated APK over a previous one without
   uninstalling first. (This is fine for sideloading; it is **not** a Play
   Store–ready signature.)
4. Uploads the finished APK as a workflow artifact.

To build locally instead, you'll need the Android NDK on your `PATH` and a
compiled `libllama.so` for your target ABI in
`android/app/src/main/jniLibs/<abi>/` before running `flutter build apk`.

## Status

Early scaffold — chat, memory, and server-management UI are wired up;
model loading and generation go through the real `llama_cpp_dart` API
(`LlamaParent` + `LlamaScope`), but this hasn't yet been run against a real
device/model. Treat native-library and API surface details as "verify
against whatever `llama_cpp_dart` version is pinned in `pubspec.yaml`" —
that package's public API has changed release to release.

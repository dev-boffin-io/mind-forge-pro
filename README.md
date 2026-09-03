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
| Inference | [llama_cpp_dart](https://pub.dev/packages/llama_cpp_dart) 0.9.x, off the UI thread via `LlamaEngine`/`EngineSession` |
| Local server | `shelf` + `shelf_router` |
| Memory / RAG | `sqflite` + a pure-Dart TF-IDF keyword ranker |
| Native actions | a `MethodChannel` the model can trigger via `<ACTION: X>` tags |

## Building

CI (`.github/workflows/build-apk.yml`) does everything needed for a
sideloadable release APK — no production keystore required:

1. Downloads `llama_cpp_dart`'s prebuilt Android AAR (CPU + mtmd,
   arm64-v8a) from its GitHub Releases, matching the exact version pinned
   in `pubspec.yaml`, into `android/app/libs/llama-cpp-dart.aar`. No native
   compilation happens in this project at all — 0.9.x ships binaries built
   against its own pinned llama.cpp commit, which is also why the earlier
   from-source NDK build (against an unpinned llama.cpp clone) kept hitting
   ABI mismatches.
2. Runs `flutter build apk --release --target-platform android-arm64` with
   R8/ProGuard shrinking and native debug-symbol stripping enabled
   (`android/app/build.gradle`).
3. Signs the release build with the standard Android **debug** keystore,
   cached across runs so every build shares the same signing key — that's
   what lets you install an updated APK over a previous one without
   uninstalling first. (This is fine for sideloading; it is **not** a Play
   Store–ready signature.)
4. Uploads the finished APK as a workflow artifact.

To build locally instead, download `llama-cpp-dart.aar` yourself (see
[the package's install instructions](https://github.com/netdur/llama_cpp_dart#install))
into `android/app/libs/` before running `flutter build apk`.

## Status

Early scaffold — chat, memory, and server-management UI are wired up;
model loading and generation go through `llama_cpp_dart`'s `LlamaEngine`/
`EngineSession` API (0.9.x line — a prerelease, still pre-1.0 with
occasional breaking changes). Verify current API shape against whatever
`llama_cpp_dart` version is pinned in `pubspec.yaml` before assuming any
snippet here still matches.

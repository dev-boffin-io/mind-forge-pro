import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

enum ServerStatus { stopped, starting, running, error }

/// Owns the native llama.cpp model instance (run off the UI thread in its
/// own isolate via [LlamaParent]/[LlamaScope]) and exposes it over a local
/// HTTP API (/api/generate), mimicking the shape of Ollama's API just
/// enough that other local scripts/apps can point at this port instead.
class ServerManager {
  ServerManager._internal();
  static final ServerManager instance = ServerManager._internal();

  LlamaParent? _parent;
  LlamaScope? _scope;
  HttpServer? _httpServer;

  ServerStatus status = ServerStatus.stopped;
  String? lastError;
  String? loadedModelPath;
  int port = 8080;

  final _statusController = StreamController<ServerStatus>.broadcast();
  Stream<ServerStatus> get statusStream => _statusController.stream;

  void _setStatus(ServerStatus s) {
    status = s;
    _statusController.add(s);
  }

  /// Load a .gguf model from local storage into the native engine, running
  /// inference in a background isolate so it never blocks the Flutter UI
  /// thread. Safe to call again with a different path to hot-swap models
  /// (call [unloadModel] first).
  Future<void> loadModel(String ggufPath) async {
    try {
      await unloadModel();

      // The native library is bundled under jniLibs and extracted by
      // Android alongside the APK's own native libs, so a bare filename
      // resolves via the standard dynamic-linker search path.
      Llama.libraryPath = 'libllama.so';

      final loadCommand = LlamaLoad(
        path: ggufPath,
        modelParams: ModelParams(),
        contextParams: ContextParams()..nCtx = 4096,
        samplingParams: SamplerParams(),
        format: ChatMLFormat(),
      );

      final parent = LlamaParent(loadCommand);
      await parent.init();

      _parent = parent;
      _scope = LlamaScope(parent);
      loadedModelPath = ggufPath;
      lastError = null;
    } catch (e) {
      lastError = 'Model load failed: $e';
      _parent = null;
      _scope = null;
      _setStatus(ServerStatus.error);
      rethrow;
    }
  }

  Future<void> unloadModel() async {
    await _scope?.dispose();
    await _parent?.dispose();
    _scope = null;
    _parent = null;
    loadedModelPath = null;
  }

  bool get isModelLoaded => _scope != null;

  /// Run a single generation against the loaded model and return the full
  /// text response. Per-request token limits aren't exposed by
  /// [LlamaScope.sendPrompt] — configure `nPredict` on [SamplerParams] at
  /// load time if you need a hard cap.
  Future<String> generate(String prompt) async {
    final scope = _scope;
    if (scope == null) {
      throw StateError('No model loaded. Call loadModel() first.');
    }
    return scope.sendPrompt(prompt);
  }

  Router _buildRouter() {
    final router = Router();

    router.get('/api/health', (Request req) {
      return Response.ok(
        jsonEncode({
          'status': status.name,
          'model_loaded': isModelLoaded,
          'model_path': loadedModelPath,
        }),
        headers: {'content-type': 'application/json'},
      );
    });

    router.post('/api/generate', (Request req) async {
      try {
        final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
        final prompt = body['prompt'] as String?;
        if (prompt == null || prompt.trim().isEmpty) {
          return Response(400,
              body: jsonEncode({'error': 'Missing "prompt" field.'}),
              headers: {'content-type': 'application/json'});
        }
        final result = await generate(prompt);
        return Response.ok(
          jsonEncode({'response': result}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    return router;
  }

  /// Start listening on the configured [port] (loopback only).
  Future<void> start({int? overridePort}) async {
    if (status == ServerStatus.running) return;
    if (!isModelLoaded) {
      throw StateError('Cannot start server: no model loaded.');
    }
    if (overridePort != null) port = overridePort;

    _setStatus(ServerStatus.starting);
    try {
      final handler = const Pipeline()
          .addMiddleware(logRequests())
          .addHandler(_buildRouter().call);

      _httpServer = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, port);
      _setStatus(ServerStatus.running);
    } catch (e) {
      lastError = 'Server start failed: $e';
      _setStatus(ServerStatus.error);
      rethrow;
    }
  }

  Future<void> stop() async {
    await _httpServer?.close(force: true);
    _httpServer = null;
    _setStatus(ServerStatus.stopped);
  }

  /// Change the port. If the server is currently running it will be
  /// restarted on the new port.
  Future<void> changePort(int newPort) async {
    final wasRunning = status == ServerStatus.running;
    if (wasRunning) await stop();
    port = newPort;
    if (wasRunning) await start();
  }

  Future<void> dispose() async {
    await _httpServer?.close(force: true);
    await unloadModel();
    await _statusController.close();
  }
}

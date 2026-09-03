import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide Request;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

enum ServerStatus { stopped, starting, running, error }

/// Owns the native llama.cpp engine (off the UI thread in its own worker
/// isolate via [LlamaEngine]/[EngineSession]) and exposes it over a local
/// HTTP API (/api/generate), mimicking the shape of Ollama's API just
/// enough that other local scripts/apps can point at this port instead.
class ServerManager {
  ServerManager._internal();
  static final ServerManager instance = ServerManager._internal();

  LlamaEngine? _engine;
  EngineSession? _session;
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
  /// inference in a background worker isolate so it never blocks the
  /// Flutter UI thread. Safe to call again with a different path to
  /// hot-swap models (call [unloadModel] first).
  Future<void> loadModel(String ggufPath) async {
    try {
      await unloadModel();

      final engine = await LlamaEngine.spawn(
        // Bare filename: llama_cpp_dart 0.9.x ships its native library in
        // a proper Android AAR and resolves this internally — no manual
        // path resolution needed (unlike the retired 0.2.x line).
        libraryPath: 'libllama.so',
        modelParams: ModelParams(path: ggufPath, gpuLayers: 0),
        contextParams: const ContextParams(nCtx: 4096),
      );

      _engine = engine;
      _session = await engine.createSession();
      loadedModelPath = ggufPath;
      lastError = null;
    } catch (e) {
      lastError = 'Model load failed: $e';
      _engine = null;
      _session = null;
      _setStatus(ServerStatus.error);
      rethrow;
    }
  }

  Future<void> unloadModel() async {
    await _engine?.dispose();
    _engine = null;
    _session = null;
    loadedModelPath = null;
  }

  bool get isModelLoaded => _session != null;

  /// Run a single generation against the loaded model and return the full
  /// text response, collected from the underlying token stream.
  Future<String> generate(String prompt) async {
    final session = _session;
    if (session == null) {
      throw StateError('No model loaded. Call loadModel() first.');
    }
    final buffer = StringBuffer();
    await for (final event in session.generate(prompt: prompt, addSpecial: true)) {
      if (event is TokenEvent) {
        buffer.write(event.text);
      }
      // DoneEvent / ShiftEvent need no handling for a single-shot response.
    }
    return buffer.toString();
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

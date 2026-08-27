import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

enum ServerStatus { stopped, starting, running, error }

/// Owns the native llama.cpp model instance and exposes it over a local
/// HTTP API (/api/generate), mimicking the shape of Ollama's API just
/// enough that other local scripts/apps can point at this port instead.
class ServerManager {
  ServerManager._internal();
  static final ServerManager instance = ServerManager._internal();

  LlamaCpp? _model;
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

  /// Load a .gguf model from local storage into the native engine.
  /// Safe to call again with a different path to hot-swap models
  /// (the server must be stopped first).
  Future<void> loadModel(String ggufPath) async {
    try {
      _model?.dispose();
      final params = ContextParams()
        ..nCtx = 4096
        ..nBatch = 512;
      final loadParams = ModelParams()..nGpuLayers = 0; // CPU-only baseline

      _model = LlamaCpp(ggufPath, modelParams: loadParams, contextParams: params);
      loadedModelPath = ggufPath;
      lastError = null;
    } catch (e, st) {
      lastError = 'Model load failed: $e';
      _model = null;
      _setStatus(ServerStatus.error);
      rethrow;
    }
  }

  bool get isModelLoaded => _model != null;

  /// Run a single generation synchronously against the loaded model.
  /// Kept simple (non-streaming) for the HTTP endpoint; the in-app chat
  /// UI can call this same method directly for lower latency.
  Future<String> generate(String prompt, {int maxTokens = 512}) async {
    final model = _model;
    if (model == null) {
      throw StateError('No model loaded. Call loadModel() first.');
    }
    final buffer = StringBuffer();
    model.setPrompt(prompt);
    for (var i = 0; i < maxTokens; i++) {
      final piece = model.getNext();
      if (piece == null) break;
      buffer.write(piece);
      if (model.isDone) break;
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
        final maxTokens = (body['max_tokens'] as num?)?.toInt() ?? 512;
        if (prompt == null || prompt.trim().isEmpty) {
          return Response(400,
              body: jsonEncode({'error': 'Missing "prompt" field.'}),
              headers: {'content-type': 'application/json'});
        }
        final result = await generate(prompt, maxTokens: maxTokens);
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

  void dispose() {
    _httpServer?.close(force: true);
    _model?.dispose();
    _statusController.close();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' hide Request;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

enum ServerStatus { stopped, starting, running, error }

/// Owns the native llama.cpp engine (off the UI thread in its own worker
/// isolate via [LlamaEngine]) and exposes it over a local HTTP API
/// (/api/generate), mimicking the shape of Ollama's API just enough that
/// other local scripts/apps can point at this port instead.
///
/// Generation goes through [EngineChat] rather than a raw prompt string:
/// it applies the model's own embedded chat template
/// (`llama_chat_apply_template`) and stops cleanly at the model's actual
/// end-of-turn token, instead of us hand-formatting "User: ...\nAssistant:"
/// text that small models tend to echo back or run past into repetition
/// loops.
class ServerManager {
  ServerManager._internal();
  static final ServerManager instance = ServerManager._internal();

  LlamaEngine? _engine;
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
        // a proper Android AAR and resolves this internally.
        libraryPath: 'libllama.so',
        modelParams: ModelParams(path: ggufPath, gpuLayers: 0),
        contextParams: const ContextParams(nCtx: 4096),
      );

      _engine = engine;
      loadedModelPath = ggufPath;
      lastError = null;
    } catch (e) {
      lastError = 'Model load failed: $e';
      _engine = null;
      _setStatus(ServerStatus.error);
      rethrow;
    }
  }

  Future<void> unloadModel() async {
    await _engine?.dispose();
    _engine = null;
    loadedModelPath = null;
  }

  bool get isModelLoaded => _engine != null;

  /// Run a turn against the loaded model and return the full text response,
  /// collected from the token stream. A fresh [EngineChat] per call keeps
  /// each request independent, but [history] can seed the conversation so
  /// the model still sees the earlier user/assistant turns — it re-renders
  /// the full message list (via the model's chat template) on every call.
  /// [history] is ignored by callers that want a one-shot prompt (e.g. the
  /// HTTP /api/generate endpoint).
  Future<String> generate({
    required String systemPrompt,
    required String userMessage,
    List<ChatMessage> history = const [],
  }) async {
    final engine = _engine;
    if (engine == null) {
      throw StateError('No model loaded. Call loadModel() first.');
    }

    // Qwen3 is a thinking model: its default chat template makes it spend
    // tokens on an English chain-of-thought and then often fails to produce
    // the real answer (empty replies / echoes of the user's message) in
    // languages it's weaker at, like Bengali. Render a plain non-thinking
    // ChatML prompt manually so it answers directly.
    if (_isQwen3()) {
      return _generateRaw(
        engine,
        _renderQwen3Prompt(systemPrompt, userMessage, history),
      );
    }

    final chat = await engine.createChat();
    try {
      chat.addSystem(systemPrompt);
      for (final message in history) {
        chat.addMessage(message);
      }
      chat.addUser(userMessage);

      return await _generateRaw(engine, null, chat: chat);
    } finally {
      await chat.dispose();
    }
  }

  /// Shared streaming generation loop with the tuned sampler settings.
  Future<String> _generateRaw(
    LlamaEngine engine, [
    String? prompt,
    EngineChat? chat,
  ]) async {
    final buffer = StringBuffer();
    if (chat != null) {
      await for (final event in chat.generate(
        maxTokens: _maxTokens,
        shiftPolicy: ContextShiftPolicy.auto,
        shift: const ContextShift(nKeep: -1),
        sampler: _sampler,
      )) {
        if (event is TokenEvent) {
          buffer.write(event.text);
        }
      }
    } else {
      final session = await engine.createSession();
      try {
        await for (final event in session.generate(
          prompt: prompt,
          addSpecial: true,
          maxTokens: _maxTokens,
          shiftPolicy: ContextShiftPolicy.auto,
          shift: const ContextShift(nKeep: -1),
          sampler: _sampler,
        )) {
          if (event is TokenEvent) {
            buffer.write(event.text);
          }
        }
      } finally {
        await session.dispose();
      }
    }
    return buffer.toString();
  }

  static const _maxTokens = 2048;
  static const _sampler = SamplerParams(
    temperature: 0.7,
    topP: 0.9,
    repeatPenalty: 1.1,
    frequencyPenalty: 0.1,
    presencePenalty: 0.1,
  );

  /// Render a Qwen non-thinking ChatML prompt. No "thinking"/reasoning
  /// header is emitted, so the model answers directly.
  String _renderQwen3Prompt(
    String systemPrompt,
    String userMessage,
    List<ChatMessage> history,
  ) {
    final buffer = StringBuffer();
    buffer.write('<|im_start|>system\n$systemPrompt<|im_end|>\n');
    for (final message in history) {
      buffer.write(
        '<|im_start|>${message.role}\n${message.content}<|im_end|>\n',
      );
    }
    buffer.write('<|im_start|>user\n$userMessage<|im_end|>\n');
    buffer.write('<|im_start|>assistant\n');
    return buffer.toString();
  }

  bool _isQwen3() =>
      (loadedModelPath?.toLowerCase() ?? '').contains('qwen3');

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
        final systemPrompt = (body['system'] as String?)?.trim() ?? '';
        final result = await generate(
          systemPrompt: systemPrompt.isEmpty
              ? 'You are a helpful assistant. Always respond in the same '
                    'language the user writes in. If the user writes in '
                    'Bengali, respond in Bengali. If the user writes in '
                    'English, respond in English.'
              : systemPrompt,
          userMessage: prompt,
        );
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

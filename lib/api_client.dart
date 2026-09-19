import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:llama_cpp_dart/llama_cpp_dart.dart' as llama;

import 'app_settings.dart';

/// A chat backend that calls a remote OpenAI-compatible or Ollama endpoint.
///
/// Implementations read their configuration from [AppSettings] at call time,
/// so edits made in the Settings tab take effect immediately.
abstract class RemoteApiClient {
  String get label;

  Future<String> generate({
    required String systemPrompt,
    required String userMessage,
    List<llama.ChatMessage> history = const [],
  });
}

/// Resolve the active client for [type], or null when using the local engine.
RemoteApiClient? resolveRemoteClient(BackendType type) {
  switch (type) {
    case BackendType.openai:
      return OpenAiCompatibleClient();
    case BackendType.ollama:
      return OllamaClient();
    case BackendType.local:
      return null;
  }
}

/// OpenAI-compatible `/chat/completions` client. Works with the official
/// OpenAI API and any local/server provider that mirrors the same schema.
class OpenAiCompatibleClient implements RemoteApiClient {
  OpenAiCompatibleClient({AppSettings? settings})
      : _settings = settings ?? AppSettings.instance;

  final AppSettings _settings;

  @override
  String get label => 'OpenAI-compatible';

  @override
  Future<String> generate({
    required String systemPrompt,
    required String userMessage,
    List<llama.ChatMessage> history = const [],
  }) async {
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
      for (final message in history)
        {'role': message.role, 'content': message.content},
      {'role': 'user', 'content': userMessage},
    ];

    final uri = Uri.parse('${_settings.openaiBaseUrl}/chat/completions');
    final apiKey = _settings.openaiApiKey;

    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model': _settings.openaiModel,
            'messages': messages,
            'temperature': 0.7,
            'max_tokens': 2048,
            'stream': false,
          }),
        )
        .timeout(const Duration(minutes: 2));

    if (response.statusCode != 200) {
      throw Exception('$_label error ${response.statusCode}: ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List<dynamic>? ?? const [];
    if (choices.isEmpty) {
      throw Exception('$_label returned no choices.');
    }
    final choice = choices.first as Map<String, dynamic>;
    final content = (choice['message'] as Map<String, dynamic>?)?['content'];
    return (content ?? '').toString().trim();
  }
}

/// Ollama `/api/chat` client, pointed at a local or tunneled remote host.
class OllamaClient implements RemoteApiClient {
  OllamaClient({AppSettings? settings})
      : _settings = settings ?? AppSettings.instance;

  final AppSettings _settings;

  @override
  String get label => 'Ollama';

  @override
  Future<String> generate({
    required String systemPrompt,
    required String userMessage,
    List<llama.ChatMessage> history = const [],
  }) async {
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
      for (final message in history)
        {'role': message.role, 'content': message.content},
      {'role': 'user', 'content': userMessage},
    ];

    final uri = Uri.parse('${_settings.ollamaHost}/api/chat');
    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': _settings.ollamaModel,
            'messages': messages,
            'stream': false,
            'options': {
              'temperature': 0.7,
              'num_predict': 2048,
              'repeat_penalty': 1.1,
            },
          }),
        )
        .timeout(const Duration(minutes: 2));

    if (response.statusCode != 200) {
      throw Exception('$_label error ${response.statusCode}: ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final content = (decoded['message'] as Map<String, dynamic>?)?['content'];
    return (content ?? '').toString().trim();
  }
}
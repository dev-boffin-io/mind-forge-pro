import 'dart:async';
import 'package:flutter/services.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' as llama;

import 'api_client.dart';
import 'app_settings.dart';
import 'memory_agent.dart';
import 'server_manager.dart';

enum ChatRole { user, assistant, system }

class ChatMessage {
  final ChatRole role;
  final String content;
  final DateTime timestamp;

  ChatMessage({required this.role, required this.content, DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();
}

/// Recognized inline action tags the model can emit, e.g. "<ACTION: FLASHLIGHT>".
/// Extend this map as more native capabilities are wired up.
final _actionPattern = RegExp(r'<ACTION:\s*([A-Z_]+)>');

/// Reasoning tags emitted by thinking models (DeepSeek-R1, Qwen3, etc.).
/// The chain-of-thought inside these tags is internal reasoning and should
/// never be shown to the user.
final List<RegExp> _reasoningPatterns = [
  RegExp(r'<thought[^>]*>[\s\S]*?</thought\s*>', caseSensitive: false),
  RegExp(r'<think[^>]*>[\s\S]*?</think\s*>', caseSensitive: false),
  RegExp(r'<reasoning[^>]*>[\s\S]*?</reasoning\s*>', caseSensitive: false),
  RegExp(r'<\|thinking\|>[\s\S]*?</\|thinking\|>', caseSensitive: false),
  RegExp(r'<\|thought\|>[\s\S]*?</\|thought\|>', caseSensitive: false),
];

/// Role labels / special tokens that mark where the model stopped answering
/// and started running the transcript on its own. Anything from the first
/// such marker onward is discarded.
final List<RegExp> _transcriptMarkers = [
  RegExp(r'<\|im_start\|>', caseSensitive: false),
  RegExp(r'<\|im_end\|>', caseSensitive: false),
  RegExp(r'</?s>', caseSensitive: false),
  RegExp(r'\[/INST\]', caseSensitive: false),
  RegExp(r'### (?:Human|Assistant)\s*:', caseSensitive: false),
];

/// Cut [text] at the first transcript-continuation marker (a stray role
/// label or special token) and drop a leading "Assistant:"/"AI:" template
/// prefix so only the model's actual answer remains.
String _truncateAtTranscriptMarker(String text) {
  var work = text.replaceFirst(
    RegExp(r'^(?:Assistant|AI)\s*:\s*', caseSensitive: false),
    '',
  );
  final roles = RegExp(
    r'(?:\n\s*)(?:User|Assistant|System|Human|AI)\s*:',
    caseSensitive: false,
  );
  final roleMatch = roles.firstMatch(work);
  if (roleMatch != null) work = work.substring(0, roleMatch.start);
  for (final marker in _transcriptMarkers) {
    final m = marker.firstMatch(work);
    if (m != null) {
      work = work.substring(0, m.start);
      break;
    }
  }
  return work;
}

/// Orchestrates a single turn: retrieve relevant memory -> build a
/// context-augmented prompt -> run inference -> persist -> dispatch any
/// native actions the model requested.
class ChatLogic {
  static const _actionChannel = MethodChannel('mind_forge_pro/actions');
  static const _maxAttempts = 3;

  final MemoryAgent memory;
  final ServerManager server;

  ChatLogic({MemoryAgent? memory, ServerManager? server})
      : memory = memory ?? MemoryAgent(),
        server = server ?? ServerManager.instance;

  final List<ChatMessage> history = [];

  /// Send a user message, get the assistant's reply, and handle any
  /// side effects (persistence + native actions).
  ///
  /// Prior user/assistant turns in [history] are seeded into the model's
  /// prompt so a conversation stays coherent across turns (system-role
  /// entries, e.g. error notices, are excluded).
  Future<ChatMessage> send(String userInput) async {
    final prior = history
        .where((m) => m.role == ChatRole.user || m.role == ChatRole.assistant)
        .map((m) => llama.ChatMessage(role: m.role.name, content: m.content))
        .toList();

    history.add(ChatMessage(role: ChatRole.user, content: userInput));
    await memory.insert('User: $userInput');

    final relevant = await memory.retrieveRelevant(userInput, topK: 5);
    final systemPrompt = _buildSystemPrompt(relevant);

    final client = resolveRemoteClient(AppSettings.instance.backendType);
    final reply = await _generateReply(
      userInput,
      prior,
      systemPrompt,
      client: client,
    );
    final cleanReply = await _handleActions(reply);

    final assistantMessage = ChatMessage(role: ChatRole.assistant, content: cleanReply);
    history.add(assistantMessage);
    await memory.insert('Assistant: $cleanReply');

    return assistantMessage;
  }

  /// Agentic self-correction loop: generate -> clean -> validate -> retry.
  ///
  /// Small on-device models routinely produce invalid turns — empty replies,
  /// echoes of the user's message, leaked reasoning tags, or transcript
  /// continuation. When a turn fails validation, the failure is fed back to
  /// the model as a corrective request and the answer is regenerated, so the
  /// final reply is clean and natural.
  Future<String> _generateReply(
    String userInput,
    List<llama.ChatMessage> prior,
    String systemPrompt, {
    RemoteApiClient? client,
  }) async {
    var history = prior;
    var userMessage = userInput;
    var lastReply = '';
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      final raw = client != null
          ? await client.generate(
              systemPrompt: systemPrompt,
              userMessage: userMessage,
              history: history,
            )
          : await server.generate(
              systemPrompt: systemPrompt,
              userMessage: userMessage,
              history: history,
            );
      final cleaned = _cleanRawReply(raw);
      final problem = _validateReply(cleaned, userInput);
      if (problem == null) return cleaned;

      lastReply = cleaned;
      history = [
        ...prior,
        llama.ChatMessage(role: 'assistant', content: raw),
      ];
      userMessage = 'Your previous reply was invalid because it was $problem. '
          'It was not shown to the user. Do not use any thinking or '
          'reasoning blocks. The user\'s actual question was '
          '"$userInput". Answer it directly and naturally in the user\'s '
          'language now.';
    }
    return lastReply;
  }

  /// Remove reasoning/thinking blocks and truncate any transcript
  /// continuation the model produced past its turn.
  String _cleanRawReply(String raw) {
    var text = raw;
    for (final pattern in _reasoningPatterns) {
      text = text.replaceAll(pattern, ' ');
    }
    return _truncateAtTranscriptMarker(text).trim();
  }

  /// Returns a description of why [reply] is invalid, or null if it's fine.
  String? _validateReply(String reply, String userInput) {
    if (reply.trim().isEmpty) {
      return 'empty';
    }
    if (_normalize(reply) == _normalize(userInput)) {
      return 'a copy of the user\'s message';
    }
    return null;
  }

  /// Collapse to bare words so minor punctuation/whitespace differences
  /// don't hide a pure echo of the user's input.
  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');

  /// Builds only the system-role content (persona + memory context).
  /// The user's message is passed to [ServerManager.generate] separately
  /// so EngineChat can apply the model's own chat template — no manual
  /// "User:"/"Assistant:" text for the model to see and potentially echo
  /// back or continue past.
  String _buildSystemPrompt(List<MemoryEntry> context) {
    final buffer = StringBuffer();
    buffer.writeln(
      'Your name is Mind-Forge, an offline personal AI assistant running '
      'entirely on-device. '
      'Always respond in the same language the user writes in (Bengali, '
      'English, etc.) and mirror it naturally without announcing the switch. '
      'Answer directly, without thinking out loud: do not output any '
      'reasoning or "thinking" blocks, just the answer. '
      'Never repeat the user\'s question back at them. Never start your '
      'reply with "User:" or "Assistant:" and never continue the '
      'conversation on your own.',
    );
    if (context.isNotEmpty) {
      buffer.writeln('\nRelevant memory:');
      for (final entry in context) {
        final clean = entry.content
            .replaceFirst(RegExp(r'^(User|Assistant):\s*'), '');
        buffer.writeln('- $clean');
      }
    }
    return buffer.toString();
  }

  /// Scan the model's raw output for "<ACTION: X>" tags, dispatch each
  /// over a MethodChannel to native Android code, and strip the tags
  /// from the text shown to the user.
  Future<String> _handleActions(String rawReply) async {
    final matches = _actionPattern.allMatches(rawReply);
    for (final match in matches) {
      final action = match.group(1);
      if (action == null) continue;
      try {
        await _actionChannel.invokeMethod('runAction', {'action': action});
      } on PlatformException catch (e) {
        // Non-fatal: log and continue, don't break the chat response.
        // ignore: avoid_print
        print('Action "$action" failed: ${e.message}');
      }
    }
    return rawReply.replaceAll(_actionPattern, '').trim();
  }
}

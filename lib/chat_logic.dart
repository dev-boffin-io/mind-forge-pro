import 'dart:async';
import 'package:flutter/services.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' as llama;

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

/// Orchestrates a single turn: retrieve relevant memory -> build a
/// context-augmented prompt -> run inference -> persist -> dispatch any
/// native actions the model requested.
class ChatLogic {
  static const _actionChannel = MethodChannel('mind_forge_pro/actions');

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

    final rawReply = await server.generate(
      systemPrompt: systemPrompt,
      userMessage: userInput,
      history: prior,
    );
    final cleanReply = await _handleActions(rawReply);

    final assistantMessage = ChatMessage(role: ChatRole.assistant, content: cleanReply);
    history.add(assistantMessage);
    await memory.insert('Assistant: $cleanReply');

    return assistantMessage;
  }

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
      'Always respond in the same language the user writes in. '
      'If the user writes in Bengali, respond in Bengali. '
      'If the user writes in English, respond in English. '
      'Mirror the user\'s language naturally without announcing the switch.',
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

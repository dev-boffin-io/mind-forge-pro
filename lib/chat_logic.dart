import 'dart:async';
import 'package:flutter/services.dart';

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
  Future<ChatMessage> send(String userInput) async {
    history.add(ChatMessage(role: ChatRole.user, content: userInput));
    await memory.insert('User: $userInput');

    final relevant = await memory.retrieveRelevant(userInput, topK: 5);
    final prompt = _buildPrompt(userInput, relevant);

    final rawReply = await server.generate(prompt);
    final cleanReply = await _handleActions(rawReply);

    final assistantMessage = ChatMessage(role: ChatRole.assistant, content: cleanReply);
    history.add(assistantMessage);
    await memory.insert('Assistant: $cleanReply');

    return assistantMessage;
  }

  String _buildPrompt(String userInput, List<MemoryEntry> context) {
    final buffer = StringBuffer();
    buffer.writeln(
      'You are Mind-Forge, an offline personal AI assistant running entirely '
      'on-device. Use the memory notes below only if relevant.',
    );
    if (context.isNotEmpty) {
      buffer.writeln('\n--- Relevant memory ---');
      for (final entry in context) {
        buffer.writeln('- ${entry.content}');
      }
      buffer.writeln('--- end memory ---\n');
    }
    buffer.writeln('User: $userInput');
    buffer.write('Assistant:');
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

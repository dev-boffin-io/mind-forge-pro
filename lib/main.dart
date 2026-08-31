import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'chat_logic.dart';
import 'memory_agent.dart';
import 'server_manager.dart';

void main() {
  runApp(const MindForgeApp());
}

class MindForgeApp extends StatelessWidget {
  const MindForgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mind-Forge Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tabIndex = 0;
  final ChatLogic _chatLogic = ChatLogic();

  @override
  Widget build(BuildContext context) {
    final pages = [
      ChatTab(chatLogic: _chatLogic),
      MemoryTab(memory: _chatLogic.memory),
      const ServerConfigTab(),
    ];

    return Scaffold(
      body: SafeArea(child: pages[_tabIndex]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Chat'),
          NavigationDestination(icon: Icon(Icons.storage_outlined), label: 'Memory DB'),
          NavigationDestination(icon: Icon(Icons.dns_outlined), label: 'Server Config'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chat tab
// ---------------------------------------------------------------------------

class ChatTab extends StatefulWidget {
  final ChatLogic chatLogic;
  const ChatTab({super.key, required this.chatLogic});

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;

  Future<void> _onSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _controller.clear();

    try {
      await widget.chatLogic.send(text);
    } catch (e) {
      final friendly = e.toString().contains('No model loaded')
          ? 'No model loaded yet — go to Server Config, select a .gguf model, and start the server first.'
          : 'Error: $e';
      widget.chatLogic.history.add(
        ChatMessage(role: ChatRole.system, content: friendly),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.chatLogic.history;
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: messages.length,
            itemBuilder: (context, i) => _MessageBubble(message: messages[i]),
          ),
        ),
        if (_sending) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    hintText: 'Ask Mind-Forge...',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onSubmitted: (_) => _onSend(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _sending ? null : _onSend,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final isSystem = message.role == ChatRole.system;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: isSystem
              ? Colors.red.withOpacity(0.15)
              : isUser
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(message.content),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Memory DB tab
// ---------------------------------------------------------------------------

class MemoryTab extends StatefulWidget {
  final MemoryAgent memory;
  const MemoryTab({super.key, required this.memory});

  @override
  State<MemoryTab> createState() => _MemoryTabState();
}

class _MemoryTabState extends State<MemoryTab> {
  late Future<List<MemoryEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.memory.all();
  }

  void _refresh() => setState(() => _future = widget.memory.all());

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Text('Stored Memories', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await widget.memory.clearAll();
                  _refresh();
                },
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear all'),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<MemoryEntry>>(
            future: _future,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final entries = snapshot.data!;
              if (entries.isEmpty) {
                return const Center(child: Text('No memories stored yet.'));
              }
              return ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, i) {
                  final entry = entries[i];
                  return ListTile(
                    title: Text(entry.content, maxLines: 3, overflow: TextOverflow.ellipsis),
                    subtitle: Text(entry.createdAt.toLocal().toString()),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await widget.memory.delete(entry.id!);
                        _refresh();
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Server Config tab
// ---------------------------------------------------------------------------

class ServerConfigTab extends StatefulWidget {
  const ServerConfigTab({super.key});

  @override
  State<ServerConfigTab> createState() => _ServerConfigTabState();
}

class _ServerConfigTabState extends State<ServerConfigTab> {
  final _server = ServerManager.instance;
  final _portController = TextEditingController(text: '8080');
  String? _modelPath;
  bool _busy = false;
  String? _errorText;

  Future<void> _pickModel() async {
    setState(() => _errorText = null);
    try {
      // file_picker's default picker uses Android's Storage Access
      // Framework (ACTION_OPEN_DOCUMENT) — no runtime storage permission
      // is needed for it, so we go straight to the picker.
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gguf'],
      );
      final path = result?.files.single.path;
      if (path == null) return;

      setState(() => _busy = true);
      await _server.loadModel(path);
      setState(() => _modelPath = path);
    } catch (e) {
      setState(() => _errorText = e.toString());
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _toggleServer() async {
    setState(() {
      _busy = true;
      _errorText = null;
    });
    try {
      if (_server.status == ServerStatus.running) {
        await _server.stop();
      } else {
        final port = int.tryParse(_portController.text) ?? 8080;
        await _server.start(overridePort: port);
      }
    } catch (e) {
      setState(() => _errorText = e.toString());
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _server.status == ServerStatus.running;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Model', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(_modelPath ?? 'No .gguf model loaded.'),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _pickModel,
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('Select .gguf model'),
        ),
        const Divider(height: 32),
        const Text('Local Server', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _portController,
          keyboardType: TextInputType.number,
          enabled: !running,
          decoration: const InputDecoration(
            labelText: 'Port',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(
              running ? Icons.check_circle : Icons.circle_outlined,
              color: running ? Colors.green : Colors.grey,
            ),
            const SizedBox(width: 8),
            Text('Status: ${_server.status.name}'),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: (_busy || !_server.isModelLoaded) ? null : _toggleServer,
          icon: Icon(running ? Icons.stop : Icons.play_arrow),
          label: Text(running ? 'Stop server' : 'Start server'),
        ),
        if (!_server.isModelLoaded)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Load a model before starting the server.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        if (_errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_errorText!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 12),
        Text(
          'Other apps/scripts can send POST requests to '
          'http://127.0.0.1:${_portController.text}/api/generate',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }
}

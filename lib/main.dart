import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'chat_logic.dart';
import 'memory_agent.dart';
import 'server_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.instance.load();
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
      const SettingsTab(),
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
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
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
          ? 'No model loaded yet — go to Server Config and select a .gguf model first. In-app chat does not need the HTTP server; it only needs a loaded model.'
          : 'Error: $e';
      widget.chatLogic.history.add(
        ChatMessage(role: ChatRole.system, content: friendly),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  /// Shows which chat backend is active. When the local engine is selected
  /// but no model is loaded, prompts the user to pick a .gguf file. When a
  /// remote backend is selected, shows its endpoint so it's obvious where
  /// answers are coming from.
  Widget _backendStatusBanner() {
    final settings = AppSettings.instance;
    final String message;
    final Color color;
    if (settings.backendType == BackendType.local) {
      if (widget.chatLogic.server.isModelLoaded) return const SizedBox.shrink();
      message = 'No model loaded — open Server Config and select a .gguf model to start chatting.';
      color = Colors.amber;
    } else {
      final endpoint = settings.backendType == BackendType.openai
          ? settings.openaiBaseUrl
          : settings.ollamaHost;
      message = 'Chatting via ${settings.backendType.name} backend ($endpoint)';
      color = Colors.lightGreenAccent;
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(fontSize: 12, color: color),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
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
        _backendStatusBanner(),
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
      // FileType.custom + allowedExtensions can throw on some Android
      // OEM document-provider implementations when the extension (like
      // .gguf) has no registered MIME type — even with the extension
      // given correctly, without a leading dot. Pick from all files and
      // validate the extension ourselves instead.
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      final path = result?.files.single.path;
      if (path == null) return;
      if (!path.toLowerCase().endsWith('.gguf')) {
        setState(() => _errorText = 'Please choose a .gguf model file.');
        return;
      }

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

// ---------------------------------------------------------------------------
// Settings tab (remote API configuration)
// ---------------------------------------------------------------------------

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  final _settings = AppSettings.instance;

  late final _openaiBaseController =
      TextEditingController(text: _settings.openaiBaseUrl);
  late final _openaiKeyController =
      TextEditingController(text: _settings.openaiApiKey);
  late final _openaiModelController =
      TextEditingController(text: _settings.openaiModel);
  late final _ollamaHostController =
      TextEditingController(text: _settings.ollamaHost);
  late final _ollamaModelController =
      TextEditingController(text: _settings.ollamaModel);

  bool _saving = false;
  String? _info;

  @override
  void dispose() {
    _openaiBaseController.dispose();
    _openaiKeyController.dispose();
    _openaiModelController.dispose();
    _ollamaHostController.dispose();
    _ollamaModelController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _info = null;
    });
    await _settings.setOpenAi(
      baseUrl: _openaiBaseController.text,
      apiKey: _openaiKeyController.text,
      model: _openaiModelController.text,
    );
    await _settings.setOllama(
      host: _ollamaHostController.text,
      model: _ollamaModelController.text,
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _info = 'Settings saved.';
    });
    // Reflect normalized/defaulted values back into the fields.
    _openaiBaseController.text = _settings.openaiBaseUrl;
    _openaiModelController.text = _settings.openaiModel;
    _ollamaHostController.text = _settings.ollamaHost;
    _ollamaModelController.text = _settings.ollamaModel;
  }

  @override
  Widget build(BuildContext context) {
    final hintStyle = TextStyle(
      fontSize: 12,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Chat Backend',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SegmentedButton<BackendType>(
          segments: const [
            ButtonSegment(value: BackendType.local, label: Text('Local')),
            ButtonSegment(value: BackendType.openai, label: Text('OpenAI')),
            ButtonSegment(value: BackendType.ollama, label: Text('Ollama')),
          ],
          selected: {_settings.backendType},
          onSelectionChanged: (selection) {
            _settings.setBackendType(selection.first);
            setState(() {});
          },
        ),
        const SizedBox(height: 4),
        Text(
          'Where Mind-Forge runs its conversations.',
          style: hintStyle,
        ),
        const Divider(height: 32),

        const Text('OpenAI-compatible endpoint',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _openaiBaseController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://api.openai.com/v1',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _openaiKeyController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'API Key',
            hintText: 'sk-...',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _openaiModelController,
          decoration: const InputDecoration(
            labelText: 'Model',
            hintText: 'gpt-4o-mini',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Leave the Base URL blank to use ${AppSettings.defaultOpenaiBaseUrl}. '
          'A blank API key sends no authorization header (fine for local '
          'OpenAI-compatible servers).',
          style: hintStyle,
        ),
        const Divider(height: 32),

        const Text('Ollama host',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _ollamaHostController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Host / Tunnel URL',
            hintText: 'http://localhost:11434',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ollamaModelController,
          decoration: const InputDecoration(
            labelText: 'Model',
            hintText: 'llama3.2',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Leave blank to use ${AppSettings.defaultOllamaHost}. Use a tunnel '
          'URL (e.g. Cloudflare) to reach a remote Ollama from this device.',
          style: hintStyle,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: const Text('Save settings'),
        ),
        if (_info != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_info!, style: const TextStyle(color: Colors.green)),
          ),
      ],
    );
  }
}

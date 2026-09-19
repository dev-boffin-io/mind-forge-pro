import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where [ChatLogic.send] routes conversation turns.
enum BackendType { local, openai, ollama }

/// Persistent, user-editable runtime configuration (singleton).
///
/// Backed by `shared_preferences` so custom remote endpoints/keys survive
/// restarts. Every field has a documented default that is used when the user
/// leaves the corresponding field blank, so the app keeps working out of the
/// box (local llama.cpp, OpenAI's official API, or a local Ollama).
///
/// Instances that need the latest values (e.g. API clients) read these fields
/// synchronously at call time — edits apply immediately without restarting.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const _kBackend = 'backend_type';
  static const _kOpenaiBase = 'openai_base_url';
  static const _kOpenaiKey = 'openai_api_key';
  static const _kOpenaiModel = 'openai_model';
  static const _kOllamaHost = 'ollama_host';
  static const _kOllamaModel = 'ollama_model';

  static const String defaultOpenaiBaseUrl = 'https://api.openai.com/v1';
  static const String defaultOpenaiModel = 'gpt-4o-mini';
  static const String defaultOllamaHost = 'http://localhost:11434';
  static const String defaultOllamaModel = 'llama3.2';

  SharedPreferences? _prefs;

  BackendType backendType = BackendType.local;
  String openaiBaseUrl = defaultOpenaiBaseUrl;
  String openaiApiKey = '';
  String openaiModel = defaultOpenaiModel;
  String ollamaHost = defaultOllamaHost;
  String ollamaModel = defaultOllamaModel;

  bool get isLoaded => _prefs != null;

  /// Load persisted values; call once before `runApp`.
  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    backendType = BackendType.values.firstWhere(
      (t) => t.name == _prefs!.getString(_kBackend),
      orElse: () => BackendType.local,
    );
    openaiBaseUrl = _prefs!.getString(_kOpenaiBase) ?? defaultOpenaiBaseUrl;
    openaiApiKey = _prefs!.getString(_kOpenaiKey) ?? '';
    openaiModel = _prefs!.getString(_kOpenaiModel) ?? defaultOpenaiModel;
    ollamaHost = _prefs!.getString(_kOllamaHost) ?? defaultOllamaHost;
    ollamaModel = _prefs!.getString(_kOllamaModel) ?? defaultOllamaModel;
    notifyListeners();
  }

  Future<void> setBackendType(BackendType type) async {
    backendType = type;
    await _prefs?.setString(_kBackend, type.name);
    notifyListeners();
  }

  /// Save OpenAI-compatible endpoint config. Blank fields fall back to the
  /// standard defaults so callers never send empty URLs.
  Future<void> setOpenAi({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    openaiBaseUrl = _normalizeUrl(baseUrl, defaultOpenaiBaseUrl);
    openaiApiKey = apiKey.trim();
    openaiModel = model.trim().isEmpty ? defaultOpenaiModel : model.trim();
    await _prefs?.setString(_kOpenaiBase, openaiBaseUrl);
    await _prefs?.setString(_kOpenaiKey, openaiApiKey);
    await _prefs?.setString(_kOpenaiModel, openaiModel);
    notifyListeners();
  }

  /// Save Ollama host config. Blank fields fall back to the local default.
  Future<void> setOllama({
    required String host,
    required String model,
  }) async {
    ollamaHost = _normalizeUrl(host, defaultOllamaHost);
    ollamaModel = model.trim().isEmpty ? defaultOllamaModel : model.trim();
    await _prefs?.setString(_kOllamaHost, ollamaHost);
    await _prefs?.setString(_kOllamaModel, ollamaModel);
    notifyListeners();
  }

  /// Trim whitespace and any trailing slashes; fall back to [fallback] when
  /// the input is blank.
  static String _normalizeUrl(String url, String fallback) {
    final trimmed = url.trim().replaceAll(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? fallback : trimmed;
  }
}
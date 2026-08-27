import 'dart:async';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// A single stored memory / note.
class MemoryEntry {
  final int? id;
  final String content;
  final DateTime createdAt;

  MemoryEntry({this.id, required this.content, required this.createdAt});

  Map<String, Object?> toMap() => {
        'id': id,
        'content': content,
        'created_at': createdAt.toIso8601String(),
      };

  factory MemoryEntry.fromMap(Map<String, Object?> map) => MemoryEntry(
        id: map['id'] as int?,
        content: map['content'] as String,
        createdAt: DateTime.parse(map['created_at'] as String),
      );
}

/// Handles persistent storage of notes/conversation turns and a lightweight
/// local RAG (retrieval-augmented generation) lookup over them.
///
/// Retrieval uses a pure-Dart TF-IDF-style keyword overlap score — no
/// network calls, no external embedding service. This mirrors the
/// "hash TF-IDF" fallback tier used in earlier local-AI tooling, kept here
/// as the primary (and only) retrieval mechanism since the whole point of
/// this app is to run fully offline with zero external dependencies.
class MemoryAgent {
  static const _dbName = 'mind_forge_memory.db';
  static const _table = 'memories';

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, _dbName);
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_memories_created_at ON $_table (created_at)',
        );
      },
    );
    return _db!;
  }

  /// Persist a new note / conversation turn.
  Future<MemoryEntry> insert(String content) async {
    final db = await database;
    final entry = MemoryEntry(content: content, createdAt: DateTime.now());
    final id = await db.insert(_table, entry.toMap()..remove('id'));
    return MemoryEntry(id: id, content: content, createdAt: entry.createdAt);
  }

  Future<List<MemoryEntry>> all({int limit = 500}) async {
    final db = await database;
    final rows = await db.query(
      _table,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(MemoryEntry.fromMap).toList();
  }

  Future<void> delete(int id) async {
    final db = await database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.delete(_table);
  }

  /// Retrieve the [topK] most relevant stored memories for [query] using a
  /// simple TF-IDF-weighted cosine-style overlap score computed over the
  /// current memory set. Cheap enough to recompute on every call for a
  /// personal-scale (hundreds to low thousands of rows) memory store.
  Future<List<MemoryEntry>> retrieveRelevant(
    String query, {
    int topK = 5,
  }) async {
    final entries = await all(limit: 2000);
    if (entries.isEmpty) return [];

    final docsTokens = entries.map((e) => _tokenize(e.content)).toList();
    final queryTokens = _tokenize(query);
    if (queryTokens.isEmpty) return [];

    final df = <String, int>{};
    for (final tokens in docsTokens) {
      for (final term in tokens.toSet()) {
        df[term] = (df[term] ?? 0) + 1;
      }
    }
    final n = docsTokens.length;

    double idf(String term) {
      final occurrences = df[term] ?? 0;
      return log((n + 1) / (occurrences + 1)) + 1;
    }

    final scores = <double>[];
    for (final tokens in docsTokens) {
      final tf = <String, int>{};
      for (final t in tokens) {
        tf[t] = (tf[t] ?? 0) + 1;
      }
      double score = 0;
      for (final qt in queryTokens) {
        final termFreq = tf[qt];
        if (termFreq != null) {
          score += (termFreq / tokens.length) * idf(qt);
        }
      }
      scores.add(score);
    }

    final ranked = List<int>.generate(entries.length, (i) => i)
      ..sort((a, b) => scores[b].compareTo(scores[a]));

    return ranked
        .where((i) => scores[i] > 0)
        .take(topK)
        .map((i) => entries[i])
        .toList();
  }

  List<String> _tokenize(String text) {
    final normalized = text.toLowerCase();
    final matches = RegExp(r"[\w\u0980-\u09FF]+").allMatches(normalized);
    return matches.map((m) => m.group(0)!).where((w) => w.length > 1).toList();
  }
}

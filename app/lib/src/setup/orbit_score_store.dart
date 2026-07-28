import 'dart:convert';
import 'dart:io';

import 'orbit_review.dart';

/// Persists orbit-deck **scores only** (review mode 1). One JSON file per deck
/// under a scores directory; each file holds a list of [OrbitCardScore] — board
/// positions and SM-2 scheduling numbers, nothing else.
///
/// SECURITY: this store deliberately CANNOT leak the secret. θ_i_j (fronts) and
/// p_i_j (backs) never enter it — only positions `(stage, board)` and schedule
/// fields are written, so a stolen scores file reveals memory history, not the
/// setup. (Mode 2's TLP-encrypted fronts + p-vault are a separate store.)
///
/// Desktop-only for the default location (needs a home dir + filesystem); pass
/// an explicit [baseDir] to use it anywhere (e.g. tests). Corrupt or missing
/// files load as an empty deck — scores are a convenience, never load-bearing.
class OrbitScoreStore {
  OrbitScoreStore({Directory? baseDir}) : _baseDir = baseDir ?? _defaultBaseDir();

  final Directory _baseDir;

  /// Whether the default location is usable on this platform.
  static bool get isSupported =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  static Directory _defaultBaseDir() {
    final String sep = Platform.pathSeparator;
    final String home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return Directory('$home$sep.great-wallet${sep}orbit-scores');
  }

  /// The directory scores are read from / written to.
  String get directoryPath => _baseDir.path;

  File _fileFor(String deckId) =>
      File('${_baseDir.path}${Platform.pathSeparator}${_safeName(deckId)}.json');

  /// Load the scores for [deckId] (empty list if none / unreadable / corrupt).
  Future<List<OrbitCardScore>> load(String deckId) async {
    final File f = _fileFor(deckId);
    if (!await f.exists()) return <OrbitCardScore>[];
    try {
      final Object? data = jsonDecode(await f.readAsString());
      final List<dynamic> cards =
          (data as Map<String, dynamic>)['cards'] as List<dynamic>;
      return <OrbitCardScore>[
        for (final dynamic c in cards)
          OrbitCardScore.fromJson(c as Map<String, dynamic>),
      ];
    } catch (_) {
      // A corrupt scores file is non-critical: start the deck fresh.
      return <OrbitCardScore>[];
    }
  }

  /// Persist [scores] for [deckId], creating the directory if needed. Writes
  /// atomically (temp file + rename) so an interrupted save can't corrupt the
  /// existing deck.
  Future<void> save(String deckId, List<OrbitCardScore> scores) async {
    await _baseDir.create(recursive: true);
    final Map<String, dynamic> doc = <String, dynamic>{
      'version': 1,
      'deck': deckId,
      'cards': <Map<String, dynamic>>[
        for (final OrbitCardScore s in scores) s.toJson(),
      ],
    };
    final File target = _fileFor(deckId);
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(doc), flush: true);
    await tmp.rename(target.path);
  }

  /// Delete a deck's scores (e.g. the user resets their study history).
  Future<void> delete(String deckId) async {
    final File f = _fileFor(deckId);
    if (await f.exists()) await f.delete();
  }

  /// Deck ids the store currently holds (basenames without the `.json`).
  Future<List<String>> decks() async {
    if (!await _baseDir.exists()) return <String>[];
    final List<String> out = <String>[];
    await for (final FileSystemEntity e in _baseDir.list()) {
      final String name = e.path.split(Platform.pathSeparator).last;
      if (e is File && name.endsWith('.json')) {
        out.add(name.substring(0, name.length - '.json'.length));
      }
    }
    out.sort();
    return out;
  }

  /// Sanitise a deck id into a safe filename fragment.
  static String _safeName(String s) {
    final String cleaned = s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty ? 'deck' : cleaned;
  }
}

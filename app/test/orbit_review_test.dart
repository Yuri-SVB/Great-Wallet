import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/setup/orbit_review.dart';
import 'package:great_wallet_app/src/setup/orbit_score_store.dart';

/// Tests for the orbit review score layer (mode 1: track scores only). Pure
/// Dart + temp-dir file IO — no engine, so these always run.
void main() {
  const OrbitReviewScheduler sched = OrbitReviewScheduler();
  final DateTime day0 = DateTime(2026, 1, 1);

  group('OrbitReviewScheduler (SM-2)', () {
    test('a new card graded good schedules 1 day out, ease unchanged', () {
      final OrbitCardScore s = OrbitCardScore(stageIndex: 1, boardIndex: 0);
      expect(s.isNew, isTrue);
      expect(s.isDue(day0), isTrue, reason: 'new cards are always due');
      sched.review(s, ReviewGrade.good, now: day0);
      expect(s.repetitions, 1);
      expect(s.intervalDays, 1);
      expect(s.easeFactor, closeTo(2.5, 1e-9));
      expect(s.due, DateTime(2026, 1, 2));
      expect(s.isNew, isFalse);
    });

    test('successive goods step 1 -> 6 -> round(6*ease) days', () {
      final OrbitCardScore s = OrbitCardScore(stageIndex: 1, boardIndex: 0);
      sched.review(s, ReviewGrade.good, now: day0); // ivl 1
      sched.review(s, ReviewGrade.good, now: day0); // ivl 6
      expect(s.repetitions, 2);
      expect(s.intervalDays, 6);
      sched.review(s, ReviewGrade.good, now: day0); // ivl round(6*2.5)=15
      expect(s.repetitions, 3);
      expect(s.intervalDays, 15);
      expect(s.easeFactor, closeTo(2.5, 1e-9));
    });

    test('easy raises ease; again lapses (reset + 1 day + ease drop)', () {
      final OrbitCardScore s = OrbitCardScore(stageIndex: 2, boardIndex: 1);
      sched.review(s, ReviewGrade.easy, now: day0);
      expect(s.easeFactor, closeTo(2.6, 1e-9));
      expect(s.repetitions, 1);

      sched.review(s, ReviewGrade.again, now: day0);
      expect(s.repetitions, 0, reason: 'lapse resets the streak');
      expect(s.intervalDays, 1);
      expect(s.lapses, 1);
      expect(s.due, DateTime(2026, 1, 2));
      expect(s.easeFactor, lessThan(2.6), reason: 'again lowers ease');
    });

    test('ease is floored at 1.3 under repeated agains', () {
      final OrbitCardScore s = OrbitCardScore(stageIndex: 1, boardIndex: 2);
      for (int i = 0; i < 20; i++) {
        sched.review(s, ReviewGrade.again, now: day0);
      }
      expect(s.easeFactor, OrbitReviewScheduler.minEase);
      expect(s.lapses, 20);
    });
  });

  group('reconcileDeck', () {
    test('keeps existing scores, adds new boards, drops removed, keeps order',
        () {
      final OrbitCardScore existing =
          OrbitCardScore(stageIndex: 0, boardIndex: 0, repetitions: 3)
            ..intervalDays = 15;
      final OrbitCardScore stale =
          OrbitCardScore(stageIndex: 9, boardIndex: 9, repetitions: 1);
      final List<({int stageIndex, int boardIndex})> keys =
          <({int stageIndex, int boardIndex})>[
        (stageIndex: 0, boardIndex: 0),
        (stageIndex: 0, boardIndex: 1),
        (stageIndex: 1, boardIndex: 0),
      ];
      final List<OrbitCardScore> merged =
          reconcileDeck(keys, <OrbitCardScore>[existing, stale]);
      expect(merged.length, 3);
      expect(merged[0].repetitions, 3, reason: 'existing score preserved');
      expect(merged[1].isNew, isTrue, reason: 'new board gets a fresh score');
      expect(merged[2].isNew, isTrue);
      expect(
        merged.any((OrbitCardScore s) => s.stageIndex == 9),
        isFalse,
        reason: 'a board no longer in the deck is dropped',
      );
    });
  });

  group('OrbitScoreStore', () {
    late Directory tmp;
    late OrbitScoreStore store;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('orbit_scores_test');
      store = OrbitScoreStore(baseDir: tmp);
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('round-trips scores for a deck', () async {
      final OrbitCardScore a =
          OrbitCardScore(stageIndex: 0, boardIndex: 0, repetitions: 2)
            ..intervalDays = 6
            ..easeFactor = 2.36
            ..lapses = 1
            ..due = DateTime(2026, 1, 7)
            ..lastReviewed = DateTime(2026, 1, 1);
      final OrbitCardScore b = OrbitCardScore(stageIndex: 1, boardIndex: 0);

      await store.save('main', <OrbitCardScore>[a, b]);
      final List<OrbitCardScore> got = await store.load('main');

      expect(got.length, 2);
      expect(got[0].stageIndex, 0);
      expect(got[0].boardIndex, 0);
      expect(got[0].repetitions, 2);
      expect(got[0].intervalDays, 6);
      expect(got[0].easeFactor, closeTo(2.36, 1e-9));
      expect(got[0].lapses, 1);
      expect(got[0].due, DateTime(2026, 1, 7));
      expect(got[0].lastReviewed, DateTime(2026, 1, 1));
      expect(got[1].isNew, isTrue);
    });

    test('missing deck loads empty; delete removes it; decks() lists ids',
        () async {
      expect(await store.load('nope'), isEmpty);
      await store.save('main', <OrbitCardScore>[
        OrbitCardScore(stageIndex: 0, boardIndex: 0),
      ]);
      await store.save('spare', <OrbitCardScore>[]);
      expect(await store.decks(), <String>['main', 'spare']);
      await store.delete('main');
      expect(await store.decks(), <String>['spare']);
    });

    test('a corrupt scores file loads as an empty deck', () async {
      await store.save('main',
          <OrbitCardScore>[OrbitCardScore(stageIndex: 0, boardIndex: 0)]);
      // Corrupt the file on disk.
      final File f = File('${tmp.path}${Platform.pathSeparator}main.json');
      await f.writeAsString('{ this is not valid json ');
      expect(await store.load('main'), isEmpty);
    });
  });
}

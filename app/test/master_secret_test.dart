import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/master_secret.dart';
import 'package:great_wallet_app/src/ffi/core_bindings.dart' show FixedRect;

/// Parity vectors for the master-secret export transcript, captured from
/// great-wall-core/burning_ship/protocol.py (`build_export_transcript` +
/// `stage_text_bytes`). If the byte layout matches, an export produced by the
/// wallet reproduces bit-for-bit with the standalone for the same setup.
void main() {
  group('MasterSecret.buildExportTranscript', () {
    test('matches great-wall-core build_export_transcript for a known setup', () {
      // Inputs are already canonicalised ([A-Z0-9-]) — the wallet routes stage-0
      // text and the export label through the engine before they reach here, so
      // the builder only ASCII-encodes (mirrors the canonical Python output).
      final List<StageRecord> records = <StageRecord>[
        const StageRecord(
          o: 0x0102030405060708,
          p: 0x1112131415161718,
          q: -1, // 0xFFFFFFFFFFFFFFFF as a signed Dart int
          leafReRaw: 12345,
          leafImRaw: -6789,
        ),
        const StageRecord(
          o: 0x2122232425262728,
          p: 0x3132333435363738,
          q: 0x4142434445464748,
          leafReRaw: -1,
          leafImRaw: 9223372036854775807, // i64 max
        ),
      ];

      final Uint8List message = MasterSecret.buildExportTranscript(
        stage0Text: 'MAIN-STASH',
        iterations: 3,
        records: records,
        exportLabel: 'SIGNING-1',
      );

      expect(
        _hex(message),
        '000a4d41494e2d53544153480000000301020304050607081112131415161718'
        'ffffffffffffffff0000000000003039ffffffffffffe57b2122232425262728'
        '31323334353637384142434445464748ffffffffffffffff7fffffffffffffff'
        '00095349474e494e472d31',
      );
    });

    test('empty stage-0 text and empty label are length-prefixed zeros', () {
      final Uint8List message = MasterSecret.buildExportTranscript(
        stage0Text: '',
        iterations: 1,
        records: const <StageRecord>[],
        exportLabel: '',
      );
      // u16(0) ‖ u32(1) ‖ (no records) ‖ u16(0)
      expect(_hex(message), '0000000000010000');
    });
  });

  group('MasterSecret.leafCentreRaw', () {
    test('is the overflow-safe midpoint of the leaf rectangle bounds', () {
      const FixedRect rect =
          FixedRect(reMin: 100, reMax: 200, imMin: -10, imMax: 10);
      final ({int re, int im}) c = MasterSecret.leafCentreRaw(rect);
      expect(c.re, 150);
      expect(c.im, 0);
    });

    test('avoids overflow near the i64 extremes', () {
      const int hi = 0x7FFFFFFFFFFFFFFF; // i64 max
      const FixedRect rect =
          FixedRect(reMin: hi, reMax: hi, imMin: -hi, imMax: -hi);
      final ({int re, int im}) c = MasterSecret.leafCentreRaw(rect);
      // midpoint(hi, hi) == hi (no (a+b) overflow); same for the negative side.
      expect(c.re, hi);
      expect(c.im, -hi);
    });
  });

  group('MasterSecret.displayHex', () {
    test('is the first 32 hex chars (16 bytes) of the output', () {
      final Uint8List raw = Uint8List(MasterSecret.outputBytes);
      for (int i = 0; i < 16; i++) {
        raw[i] = i; // 0x00..0x0f
      }
      expect(MasterSecret.displayHex(raw), '000102030405060708090a0b0c0d0e0f');
      expect(MasterSecret.displayHex(raw).length, MasterSecret.displayChars);
    });
  });
}

String _hex(Uint8List bytes) {
  final StringBuffer sb = StringBuffer();
  for (final int b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

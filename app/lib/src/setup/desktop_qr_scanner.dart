import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zxing2/qrcode.dart';

import 'setup_crypto.dart';

/// Live-webcam scan of the provisional-key QR on **desktop** (Linux / Windows),
/// where `mobile_scanner` has no backend. `flutter_webrtc` drives the camera and
/// the pure-Dart `zxing2` decodes grabbed frames. [show] returns the 16 raw key
/// bytes, or `null` if cancelled or no camera was available.
///
/// SECURITY: the decoded key lives only in this widget's RAM and is handed
/// straight to the caller — it is never written to a file, the clipboard, or a
/// log. Holding the paper QR to the camera and scanning it back is the
/// air-gapped load path; nothing about the secret is persisted here.
///
/// Best-effort: desktop camera support in `flutter_webrtc` is young (USB cameras
/// on some Linux setups are flaky and `captureFrame()` has had desktop bugs), so
/// any failure simply closes the scanner and the user falls back to hex-load.
class DesktopKeyScanner extends StatefulWidget {
  const DesktopKeyScanner({super.key});

  /// Show the scanner as a modal dialog; completes with the 16-byte key or null.
  static Future<Uint8List?> show(BuildContext context) {
    return showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext _) => const Dialog(child: DesktopKeyScanner()),
    );
  }

  @override
  State<DesktopKeyScanner> createState() => _DesktopKeyScannerState();
}

class _DesktopKeyScannerState extends State<DesktopKeyScanner> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  MediaStream? _stream;
  Timer? _timer;
  bool _decoding = false; // one capture+decode in flight at a time
  bool _done = false; // a key was found / dialog is closing
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _renderer.initialize();
      final MediaStream stream =
          await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': false,
        // Plain `true`, not a facingMode constraint: desktop webcams have no
        // facing mode and a strict constraint can raise OverconstrainedError.
        'video': true,
      });
      if (!mounted) {
        await _disposeStream(stream);
        return;
      }
      _stream = stream;
      _renderer.srcObject = stream;
      setState(() {});
      _timer = Timer.periodic(
          const Duration(milliseconds: 500), (Timer _) => _tick());
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            'Could not open the camera (${e.runtimeType}). Close this and load '
            'with the hex key instead.');
      }
    }
  }

  Future<void> _tick() async {
    final MediaStream? stream = _stream;
    if (_decoding || _done || stream == null) return;
    _decoding = true;
    try {
      final List<MediaStreamTrack> tracks = stream.getVideoTracks();
      if (tracks.isEmpty) return;
      final ByteBuffer frame = await tracks.first.captureFrame();
      final Uint8List? key = await _decodeKey(frame.asUint8List());
      if (key != null && mounted && !_done) {
        _done = true;
        Navigator.of(context).pop(key);
      }
    } catch (_) {
      // Transient capture/decode failure (no QR in view, captureFrame hiccup);
      // the next tick tries again.
    } finally {
      _decoding = false;
    }
  }

  /// Decode the byte-mode QR from an encoded camera [frame] and return the 16
  /// key bytes, or null if no usable QR is present. The key is read from the raw
  /// **byte segment** (charset-independent) so arbitrary key bytes survive — the
  /// decoded `text` would be mangled by the decoder's charset guessing.
  static Future<Uint8List?> _decodeKey(Uint8List frame) async {
    final ui.Codec codec = await ui.instantiateImageCodec(frame);
    final ui.FrameInfo info = await codec.getNextFrame();
    final ui.Image image = info.image;
    try {
      final ByteData? rgba =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) return null;
      // A QR is monochrome (r == g == b for every cell), so reinterpreting the
      // RGBA bytes as ARGB ints is fine for luminance regardless of endianness.
      final Int32List pixels = rgba.buffer
          .asInt32List(rgba.offsetInBytes, image.width * image.height);
      final LuminanceSource source =
          RGBLuminanceSource(image.width, image.height, pixels);
      final BinaryBitmap bitmap = BinaryBitmap(HybridBinarizer(source));
      final Result result;
      try {
        result = QRCodeReader().decode(bitmap);
      } catch (_) {
        return null; // no QR found in this frame
      }
      final Object? segments =
          result.resultMetadata[ResultMetadataType.byteSegments];
      if (segments is! List || segments.isEmpty) return null;
      final Object? first = segments.first;
      if (first is! List<int> || !SetupCrypto.isValidKeyLen(first.length)) {
        return null;
      }
      return Uint8List.fromList(first); // Int8List -> unsigned bytes
    } finally {
      image.dispose();
    }
  }

  Future<void> _disposeStream(MediaStream stream) async {
    for (final MediaStreamTrack t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
  }

  @override
  void dispose() {
    _timer?.cancel();
    final MediaStream? stream = _stream;
    _renderer.srcObject = null;
    if (stream != null) {
      _disposeStream(stream); // fire-and-forget; widget is going away
    }
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error ??
                  'Hold the hand-coloured QR up to the camera — it scans and '
                      'loads automatically. The key stays in memory; nothing is '
                      'saved. Do this in private, no other cameras around.',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          SizedBox(
            height: 320,
            child: _error != null
                ? const Center(child: Icon(Icons.videocam_off, size: 48))
                : (_stream == null
                    ? const Center(child: CircularProgressIndicator())
                    : RTCVideoView(_renderer)),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

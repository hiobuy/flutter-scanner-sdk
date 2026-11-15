import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';

/// Barcode symbologies supported by both platforms.
enum BarcodeFormat {
  code128,
  code39,
  ean13,
  ean8,
  qr,
  itf;

  /// The 1D formats common on warehouse and logistics labels. This is the
  /// default: enabling fewer formats makes detection faster.
  static const Set<BarcodeFormat> warehouse1D = {code128, code39, ean13, ean8, itf};

  static const Set<BarcodeFormat> all = {code128, code39, ean13, ean8, qr, itf};

  static BarcodeFormat? tryParse(String? name) {
    for (final f in values) {
      if (f.name == name) return f;
    }
    return null;
  }
}

enum ScanMode {
  /// Accept one result, then stop accepting until [ScannerController.resume].
  /// The camera keeps running.
  single,

  /// Keep reporting results; repeats of the same value inside
  /// [ScannerConfig.dedupeWindow] are suppressed.
  continuous,
}

/// How much of the pipeline [ScannerController.pause] halts.
enum PauseLevel {
  /// Frames are still analysed, results are discarded. Resuming is instant.
  results,

  /// Frame analysis stops, preview keeps running. Resuming costs one frame.
  analysis,
}

/// Requested analysis resolution. Higher is not always faster or better.
enum ScanResolution { sd540, hd720, fhd1080 }

/// What [ScannerController.onScan] does with results that arrive while the
/// previous handler invocation is still running.
enum BusyPolicy {
  /// Discard them.
  drop,

  /// Keep only the newest one and deliver it when the handler finishes.
  keepLatest,
}

enum CameraPermission {
  granted,

  /// Not granted; asking again may show the system prompt.
  denied,

  /// The system will not prompt again; send the user to app settings.
  permanentlyDenied,

  /// Blocked by device policy (iOS parental controls / MDM).
  restricted;

  static CameraPermission parse(String? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return denied;
  }
}

enum ScannerStatus { idle, starting, running, paused, stopped, error }

/// Feedback produced natively at the moment of recognition, before the result
/// reaches Dart.
@immutable
class ScanFeedback {
  const ScanFeedback({this.vibrate = true, this.beep = false});

  static const none = ScanFeedback(vibrate: false, beep: false);

  final bool vibrate;
  final bool beep;
}

@immutable
class ScannerConfig {
  const ScannerConfig({
    this.mode = ScanMode.continuous,
    this.formats = BarcodeFormat.warehouse1D,
    this.dedupeWindow = const Duration(milliseconds: 1500),
    this.scanRegion,
    this.feedback = const ScanFeedback(),
    this.resolution = ScanResolution.hd720,
    this.zoom,
    this.autoZoom = true,
    this.confirmations = 2,
    this.fastAcceptPatterns = const [],
    this.labelHold = const Duration(milliseconds: 400),
  });

  final ScanMode mode;
  final Set<BarcodeFormat> formats;

  /// Continuous mode: a value is not reported again until this long after it
  /// was last *seen*. [Duration.zero] disables de-duplication.
  ///
  /// This is a convenience for the operator, not a replacement for
  /// server-side idempotency.
  final Duration dedupeWindow;

  /// Region of the [ScannerView] in which barcodes are accepted, as fractions
  /// (0–1) of the view's width and height. `null` accepts the whole view.
  final Rect? scanRegion;

  final ScanFeedback feedback;
  final ScanResolution resolution;

  /// Zoom ratio. `null` lets the platform choose (on iOS it compensates for
  /// the minimum focus distance of recent wide cameras).
  final double? zoom;

  /// Android: when a barcode is found but is too small to read, zoom in on it
  /// automatically, then return to [zoom] once nothing has needed it for a
  /// moment. Lets operators scan from arm's length.
  ///
  /// No effect on iOS: the system decoder reports nothing until a code is
  /// fully decoded, so there is nothing to zoom towards.
  final bool autoZoom;

  /// Android: how many consecutive frames must decode to the same value
  /// before it is reported. ML Kit occasionally misreads a blurred or
  /// partly visible 1D barcode as garbage; a misread almost never repeats.
  /// 2 costs one extra frame (~35 ms); 1 reports the first decode.
  ///
  /// No effect on iOS, whose system decoder validates internally.
  final int confirmations;

  /// Android: values that fully match one of these regular expressions
  /// (`java.util.regex` syntax) are reported on the first frame, skipping
  /// [confirmations]. Give the formats your labels actually use, for example
  /// `r'JT\d{13}'`; a misread will not match, a real code does not wait.
  /// Keep patterns specific: something as loose as `.*` defeats the check.
  ///
  /// Empty (the default) disables this. No effect on iOS.
  final List<String> fastAcceptPatterns;

  /// A label often carries more than one barcode. After a result, other
  /// values are ignored until the reported one has been out of view for this
  /// long, so resting the camera on one label gives one result: the code
  /// nearest the centre. [Duration.zero] disables it.
  final Duration labelHold;

  ScannerConfig copyWith({
    ScanMode? mode,
    Set<BarcodeFormat>? formats,
    Duration? dedupeWindow,
    Rect? scanRegion,
    bool clearScanRegion = false,
    ScanFeedback? feedback,
    ScanResolution? resolution,
    double? zoom,
    bool clearZoom = false,
    bool? autoZoom,
    int? confirmations,
    List<String>? fastAcceptPatterns,
    Duration? labelHold,
  }) {
    return ScannerConfig(
      mode: mode ?? this.mode,
      formats: formats ?? this.formats,
      dedupeWindow: dedupeWindow ?? this.dedupeWindow,
      scanRegion: clearScanRegion ? null : (scanRegion ?? this.scanRegion),
      feedback: feedback ?? this.feedback,
      resolution: resolution ?? this.resolution,
      zoom: clearZoom ? null : (zoom ?? this.zoom),
      autoZoom: autoZoom ?? this.autoZoom,
      confirmations: confirmations ?? this.confirmations,
      fastAcceptPatterns: fastAcceptPatterns ?? this.fastAcceptPatterns,
      labelHold: labelHold ?? this.labelHold,
    );
  }

  Map<String, Object?> toMap() {
    final r = scanRegion;
    return {
      'mode': mode.name,
      'formats': [for (final f in formats) f.name],
      'dedupeWindowMs': dedupeWindow.inMilliseconds,
      'region': r == null ? null : <double>[r.left, r.top, r.right, r.bottom],
      'vibrate': feedback.vibrate,
      'beep': feedback.beep,
      'resolution': resolution.name,
      'zoom': zoom,
      'autoZoom': autoZoom,
      'confirmations': confirmations,
      'fastAcceptPatterns': fastAcceptPatterns,
      'labelHoldMs': labelHold.inMilliseconds,
    };
  }
}

/// Per-result timing, kept as separate segments on purpose: decode time alone
/// is not end-to-end latency.
@immutable
class ScanTimings {
  const ScanTimings({
    required this.frameAgeMs,
    required this.decodeMs,
    required this.nativeTotalMs,
    required this.dartDeliveryMs,
  });

  /// Frame capture timestamp → analysis start (capture pipeline + queueing).
  /// `null` when the platform cannot relate the frame clock to the wall clock.
  final double? frameAgeMs;

  /// Time spent inside the decoder. `null` on iOS, where the system decodes
  /// before the plugin sees the frame.
  final double? decodeMs;

  /// Frame capture timestamp → result produced natively. Excludes focusing
  /// and everything before the decoded frame was exposed. When several
  /// frames must agree ([ScannerConfig.confirmations]), it is measured from
  /// the first of them, so the confirmation wait is included.
  final double? nativeTotalMs;

  /// Result produced natively → received in Dart.
  final double dartDeliveryMs;

  @override
  String toString() =>
      'ScanTimings(frameAge: $frameAgeMs, decode: $decodeMs, nativeTotal: $nativeTotalMs, dartDelivery: $dartDeliveryMs)';
}

@immutable
class ScanResult {
  const ScanResult({
    required this.value,
    required this.format,
    required this.timestamp,
    required this.platform,
    required this.sequence,
    required this.timings,
    this.boundingBox,
  });

  final String value;
  final BarcodeFormat format;

  /// When the native layer produced the result.
  final DateTime timestamp;

  /// `android` or `ios`.
  final String platform;

  /// Increases by one per reported result within a camera session.
  final int sequence;

  final ScanTimings timings;

  /// Location in the upright camera image, as fractions (0–1). May be null.
  final Rect? boundingBox;

  static ScanResult? fromEvent(Map<Object?, Object?> e, {required int receivedAtUs}) {
    final value = e['value'];
    final format = BarcodeFormat.tryParse(e['format'] as String?);
    if (value is! String || format == null) return null;
    final box = e['box'];
    final emitUs = (e['emitEpochUs'] as num?)?.toInt() ?? receivedAtUs;
    return ScanResult(
      value: value,
      format: format,
      timestamp: DateTime.fromMicrosecondsSinceEpoch(emitUs),
      platform: e['platform'] as String? ?? defaultTargetPlatform.name.toLowerCase(),
      sequence: (e['sequence'] as num?)?.toInt() ?? 0,
      boundingBox: box is List && box.length == 4
          ? Rect.fromLTRB(
              (box[0] as num).toDouble(),
              (box[1] as num).toDouble(),
              (box[2] as num).toDouble(),
              (box[3] as num).toDouble(),
            )
          : null,
      timings: ScanTimings(
        frameAgeMs: (e['frameAgeMs'] as num?)?.toDouble(),
        decodeMs: (e['decodeMs'] as num?)?.toDouble(),
        nativeTotalMs: (e['nativeTotalMs'] as num?)?.toDouble(),
        dartDeliveryMs: (receivedAtUs - emitUs) / 1000.0,
      ),
    );
  }

  @override
  String toString() => 'ScanResult(#$sequence ${format.name} "$value")';
}

/// How long the last [ScannerController.start] took.
@immutable
class StartupTimings {
  const StartupTimings({required this.warm, required this.sessionReadyMs, this.firstFrameMs});

  /// True when the session was restarted after [ScannerController.stop]
  /// without having been disposed.
  final bool warm;

  /// `start()` received natively → camera session running.
  final double sessionReadyMs;

  /// `start()` received natively → first frame delivered. Null until it arrives.
  final double? firstFrameMs;
}

/// Counters since the last `start()`.
@immutable
class ScannerStats {
  const ScannerStats({
    this.framesAnalyzed = 0,
    this.detections = 0,
    this.emitted = 0,
    this.duplicatesSuppressed = 0,
    this.outsideRegion = 0,
    this.heldBack = 0,
    this.fastAccepted = 0,
    this.droppedWhileBusy = 0,
  });

  /// Frames handed to the decoder. Always 0 on iOS (system decodes).
  final int framesAnalyzed;

  /// Frames (Android) or metadata callbacks (iOS) that contained a barcode.
  final int detections;

  /// Results reported to Dart.
  final int emitted;

  /// Detections suppressed by the de-duplication window.
  final int duplicatesSuppressed;

  /// Detections rejected for lying outside the scan region.
  final int outsideRegion;

  /// Detections ignored by [ScannerConfig.labelHold].
  final int heldBack;

  /// Results reported on the first frame via
  /// [ScannerConfig.fastAcceptPatterns]. Always 0 on iOS.
  final int fastAccepted;

  /// Results discarded by [ScannerController.onScan] while a handler was busy.
  final int droppedWhileBusy;
}

@immutable
class ScannerState {
  const ScannerState({
    this.status = ScannerStatus.idle,
    this.pauseLevel,
    this.permission,
    this.torchOn = false,
    this.hasTorch = false,
    this.textureId,
    this.previewSize,
    this.startup,
    this.error,
  });

  final ScannerStatus status;

  /// Set while [status] is [ScannerStatus.paused].
  final PauseLevel? pauseLevel;

  /// Last known permission; null until first queried.
  final CameraPermission? permission;
  final bool torchOn;
  final bool hasTorch;

  /// Android preview texture. Null on iOS, which uses a platform view.
  final int? textureId;

  /// Size of the upright preview image in pixels.
  final Size? previewSize;
  final StartupTimings? startup;
  final ScannerException? error;

  bool get isCameraActive => status == ScannerStatus.running || status == ScannerStatus.paused;

  ScannerState copyWith({
    ScannerStatus? status,
    PauseLevel? pauseLevel,
    bool clearPause = false,
    CameraPermission? permission,
    bool? torchOn,
    bool? hasTorch,
    int? textureId,
    bool clearTexture = false,
    Size? previewSize,
    StartupTimings? startup,
    ScannerException? error,
    bool clearError = false,
  }) {
    return ScannerState(
      status: status ?? this.status,
      pauseLevel: clearPause ? null : (pauseLevel ?? this.pauseLevel),
      permission: permission ?? this.permission,
      torchOn: torchOn ?? this.torchOn,
      hasTorch: hasTorch ?? this.hasTorch,
      textureId: clearTexture ? null : (textureId ?? this.textureId),
      previewSize: previewSize ?? this.previewSize,
      startup: startup ?? this.startup,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ScannerException implements Exception {
  const ScannerException(this.code, [this.message]);

  static const permissionDenied = 'permission_denied';
  static const cameraUnavailable = 'camera_unavailable';
  static const cameraError = 'camera_error';
  static const disposed = 'disposed';

  final String code;
  final String? message;

  @override
  String toString() => 'ScannerException($code${message == null ? '' : ': $message'})';
}

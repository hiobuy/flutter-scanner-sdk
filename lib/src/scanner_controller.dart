import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'types.dart';

/// Drives the native scanning engine.
///
/// The device camera is exclusive, so only one controller is active at a
/// time: starting a controller stops whichever one was running.
///
/// Lifecycle: [start] → ([pause] / [resume])* → [stop] → [start] … → [dispose].
/// [stop] keeps the native session configured so the next [start] is warm.
class ScannerController {
  ScannerController({ScannerConfig config = const ScannerConfig()}) : _config = config;

  @visibleForTesting
  static const MethodChannel methodChannel = MethodChannel('hiobuy_scanner/methods');

  @visibleForTesting
  static const EventChannel eventChannel = EventChannel('hiobuy_scanner/events');

  static Stream<dynamic>? _sharedEvents;
  static ScannerController? _active;

  ScannerConfig _config;
  final ValueNotifier<ScannerState> _state = ValueNotifier(const ScannerState());
  final StreamController<ScanResult> _results = StreamController<ScanResult>.broadcast();
  StreamSubscription<dynamic>? _eventSub;
  Future<void> _queue = Future<void>.value();
  Size? _viewSize;
  int _droppedWhileBusy = 0;
  bool _disposed = false;

  ScannerConfig get config => _config;

  /// Current state; listen to rebuild UI.
  ValueListenable<ScannerState> get state => _state;

  /// Accepted results. Unbuffered: a result nobody is listening for is gone.
  /// Mode gating and de-duplication have already been applied natively.
  Stream<ScanResult> get results => _results.stream;

  bool get isDisposed => _disposed;

  // ---------------------------------------------------------------- permission

  Future<CameraPermission> getPermission() async {
    final p = CameraPermission.parse(await methodChannel.invokeMethod<String>('getPermission'));
    _setState(_state.value.copyWith(permission: p));
    return p;
  }

  /// Shows the system prompt if it can still be shown.
  Future<CameraPermission> requestPermission() async {
    final p = CameraPermission.parse(await methodChannel.invokeMethod<String>('requestPermission'));
    _setState(_state.value.copyWith(permission: p));
    return p;
  }

  /// Opens this app's page in system settings, for [CameraPermission.permanentlyDenied].
  Future<bool> openAppSettings() async {
    return await methodChannel.invokeMethod<bool>('openAppSettings') ?? false;
  }

  // ----------------------------------------------------------------- lifecycle

  /// Requests permission if needed and starts camera, preview and analysis.
  /// Does nothing if the camera is already active.
  ///
  /// Throws [ScannerException] if permission is denied or the camera fails.
  Future<void> start() {
    return _enqueue(() async {
      _checkNotDisposed();
      if (_state.value.isCameraActive && identical(_active, this)) return;
      _setState(_state.value.copyWith(status: ScannerStatus.starting, clearError: true, clearPause: true));
      try {
        var permission = await getPermission();
        if (permission == CameraPermission.denied) permission = await requestPermission();
        if (permission != CameraPermission.granted) {
          throw const ScannerException(ScannerException.permissionDenied);
        }
        if (_disposed) return;

        final previous = _active;
        if (previous != null && !identical(previous, this)) previous._onTakenOver();
        _active = this;
        _eventSub ??= _events().listen(_onEvent, onError: _onEventError);
        _droppedWhileBusy = 0;

        final r = await methodChannel.invokeMapMethod<String, Object?>('start', _startArguments());
        if (_disposed || !identical(_active, this)) return;
        final w = (r?['previewWidth'] as num?)?.toDouble();
        final h = (r?['previewHeight'] as num?)?.toDouble();
        _setState(_state.value.copyWith(
          status: ScannerStatus.running,
          clearPause: true,
          textureId: (r?['textureId'] as num?)?.toInt(),
          previewSize: (w != null && h != null) ? Size(w, h) : null,
          hasTorch: r?['hasTorch'] as bool? ?? false,
          torchOn: false,
          startup: StartupTimings(
            warm: r?['warm'] as bool? ?? false,
            sessionReadyMs: (r?['sessionReadyMs'] as num?)?.toDouble() ?? 0,
          ),
        ));
      } on PlatformException catch (e) {
        final error = ScannerException(e.code, e.message);
        _setState(_state.value.copyWith(status: ScannerStatus.error, error: error));
        throw error;
      } on ScannerException catch (e) {
        _setState(_state.value.copyWith(status: ScannerStatus.error, error: e));
        rethrow;
      }
    });
  }

  /// Stops the camera session but keeps it configured for a warm [start].
  Future<void> stop() {
    return _enqueue(() async {
      if (_disposed || !identical(_active, this)) return;
      if (!_state.value.isCameraActive && _state.value.status != ScannerStatus.error) return;
      await methodChannel.invokeMethod<void>('stop');
      _setState(_state.value.copyWith(status: ScannerStatus.stopped, clearPause: true, torchOn: false));
    });
  }

  /// Halts result delivery ([PauseLevel.results]) or frame analysis
  /// ([PauseLevel.analysis]). The camera and preview keep running either way.
  Future<void> pause([PauseLevel level = PauseLevel.results]) {
    return _enqueue(() async {
      if (!_ownsRunningCamera) return;
      await methodChannel.invokeMethod<void>('pause', {'level': level.name});
      _setState(_state.value.copyWith(status: ScannerStatus.paused, pauseLevel: level));
    });
  }

  /// Resumes after [pause], or accepts the next result in [ScanMode.single].
  Future<void> resume() {
    return _enqueue(() async {
      if (!_ownsRunningCamera) return;
      await methodChannel.invokeMethod<void>('resume');
      _setState(_state.value.copyWith(status: ScannerStatus.running, clearPause: true));
    });
  }

  /// Applies a new configuration. Mode, formats, region, de-duplication and
  /// feedback change without restarting the camera; a different
  /// [ScannerConfig.resolution] rebinds it.
  Future<void> updateConfig(ScannerConfig config) {
    return _enqueue(() async {
      _checkNotDisposed();
      _config = config;
      _setState(_state.value.copyWith()); // repaint views that draw the scan region
      if (!_ownsRunningCamera) return;
      final r = await methodChannel.invokeMapMethod<String, Object?>('updateConfig', _startArguments());
      final w = (r?['previewWidth'] as num?)?.toDouble();
      final h = (r?['previewHeight'] as num?)?.toDouble();
      if (w != null && h != null) {
        _setState(_state.value.copyWith(
          previewSize: Size(w, h),
          textureId: (r?['textureId'] as num?)?.toInt(),
        ));
      }
    });
  }

  // ------------------------------------------------------------------- camera

  Future<void> setTorch(bool on) {
    return _enqueue(() async {
      if (!_ownsRunningCamera) return;
      final actual = await methodChannel.invokeMethod<bool>('setTorch', {'on': on}) ?? false;
      _setState(_state.value.copyWith(torchOn: actual));
    });
  }

  Future<void> toggleTorch() => setTorch(!_state.value.torchOn);

  /// Focuses and meters at [point], given as fractions (0–1) of the
  /// [ScannerView]. Continuous autofocus resumes automatically afterwards.
  Future<void> focusAt(Offset point) async {
    if (!_ownsRunningCamera) return;
    await methodChannel.invokeMethod<void>('focusAt', {
      'x': point.dx.clamp(0.0, 1.0),
      'y': point.dy.clamp(0.0, 1.0),
      ..._viewArguments(),
    });
  }

  /// Forgets recently seen values so the same barcode can be reported again
  /// immediately.
  Future<void> resetDedupe() async {
    if (!_ownsRunningCamera) return;
    await methodChannel.invokeMethod<void>('resetDedupe');
  }

  /// Counters since the last [start].
  Future<ScannerStats> getStats() async {
    if (!_ownsRunningCamera) return ScannerStats(droppedWhileBusy: _droppedWhileBusy);
    final m = await methodChannel.invokeMapMethod<String, Object?>('getStats') ?? const {};
    int n(String k) => (m[k] as num?)?.toInt() ?? 0;
    return ScannerStats(
      framesAnalyzed: n('framesAnalyzed'),
      detections: n('detections'),
      emitted: n('emitted'),
      duplicatesSuppressed: n('duplicatesSuppressed'),
      outsideRegion: n('outsideRegion'),
      heldBack: n('heldBack'),
      fastAccepted: n('fastAccepted'),
      droppedWhileBusy: _droppedWhileBusy,
    );
  }

  // -------------------------------------------------------------- backpressure

  /// Runs [handler] for each result, never concurrently. Results arriving
  /// while it is still running are handled per [busyPolicy], so slow business
  /// logic can never build up a backlog: at most one result is held.
  StreamSubscription<ScanResult> onScan(
    FutureOr<void> Function(ScanResult result) handler, {
    BusyPolicy busyPolicy = BusyPolicy.drop,
    void Function(Object error, StackTrace stack)? onError,
  }) {
    var busy = false;
    ScanResult? pending;

    Future<void> run(ScanResult first) async {
      busy = true;
      ScanResult? next = first;
      while (next != null) {
        try {
          await handler(next);
        } catch (e, s) {
          if (onError != null) {
            onError(e, s);
          } else {
            FlutterError.reportError(FlutterErrorDetails(exception: e, stack: s, library: 'hiobuy_scanner'));
          }
        }
        next = pending;
        pending = null;
      }
      busy = false;
    }

    return results.listen((r) {
      if (!busy) {
        run(r);
      } else if (busyPolicy == BusyPolicy.keepLatest) {
        if (pending != null) _droppedWhileBusy++;
        pending = r;
      } else {
        _droppedWhileBusy++;
      }
    });
  }

  // ------------------------------------------------------------------ teardown

  /// Releases the camera and all native resources. The controller cannot be
  /// used afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final wasActive = identical(_active, this);
    if (wasActive) _active = null;
    await _eventSub?.cancel();
    _eventSub = null;
    if (wasActive) {
      try {
        await methodChannel.invokeMethod<void>('dispose');
      } catch (_) {
        // Engine already gone (hot restart, detached engine): nothing to release.
      }
    }
    await _results.close();
    _state.dispose();
  }

  // ------------------------------------------------------------------ internal

  /// Called by [ScannerView] when its size is known or changes.
  void attachViewSize(Size size) {
    if (_viewSize == size || size.isEmpty) return;
    _viewSize = size;
    if (_ownsRunningCamera) {
      methodChannel.invokeMethod<void>('setViewport', _viewArguments());
    }
  }

  bool get _ownsRunningCamera => !_disposed && identical(_active, this) && _state.value.isCameraActive;

  Map<String, Object?> _viewArguments() => {
        'viewWidth': _viewSize?.width,
        'viewHeight': _viewSize?.height,
      };

  Map<String, Object?> _startArguments() => {..._config.toMap(), ..._viewArguments()};

  static Stream<dynamic> _events() => _sharedEvents ??= eventChannel.receiveBroadcastStream();

  void _onEvent(dynamic event) {
    if (_disposed || event is! Map || !identical(_active, this)) return;
    switch (event['type']) {
      case 'result':
        final r = ScanResult.fromEvent(event, receivedAtUs: DateTime.now().microsecondsSinceEpoch);
        if (r == null) return;
        if (_config.mode == ScanMode.single) {
          // Native has already stopped accepting; mirror it before listeners run.
          _setState(_state.value.copyWith(status: ScannerStatus.paused, pauseLevel: PauseLevel.results));
        }
        _results.add(r);
      case 'firstFrame':
        final s = _state.value.startup;
        if (s != null) {
          _setState(_state.value.copyWith(
            startup: StartupTimings(
              warm: s.warm,
              sessionReadyMs: s.sessionReadyMs,
              firstFrameMs: (event['sinceStartMs'] as num?)?.toDouble(),
            ),
          ));
        }
      case 'state':
        _applyNativeState(event);
      case 'torch':
        _setState(_state.value.copyWith(torchOn: event['on'] as bool? ?? false));
      case 'error':
        final error = ScannerException(
          event['code'] as String? ?? ScannerException.cameraError,
          event['message'] as String?,
        );
        _setState(_state.value.copyWith(
          status: event['fatal'] == true ? ScannerStatus.error : _state.value.status,
          error: error,
        ));
    }
  }

  /// Native-initiated transitions: backgrounding, interruptions, recovery.
  void _applyNativeState(Map<dynamic, dynamic> e) {
    if (_state.value.status == ScannerStatus.starting) return;
    switch (e['state']) {
      case 'running':
        _setState(_state.value.copyWith(status: ScannerStatus.running, clearPause: true, clearError: true));
      case 'paused':
        _setState(_state.value.copyWith(
          status: ScannerStatus.paused,
          pauseLevel: e['level'] == 'analysis' ? PauseLevel.analysis : PauseLevel.results,
        ));
      case 'stopped':
        _setState(_state.value.copyWith(status: ScannerStatus.stopped, clearPause: true, torchOn: false));
    }
  }

  void _onEventError(Object error) {
    if (_disposed) return;
    _setState(_state.value.copyWith(
      error: ScannerException(ScannerException.cameraError, error.toString()),
    ));
  }

  void _onTakenOver() {
    _eventSub?.cancel();
    _eventSub = null;
    if (!_disposed) {
      _setState(_state.value.copyWith(
        status: ScannerStatus.stopped,
        clearPause: true,
        clearTexture: true,
        torchOn: false,
      ));
    }
  }

  void _setState(ScannerState s) {
    if (!_disposed) _state.value = s;
  }

  void _checkNotDisposed() {
    if (_disposed) throw const ScannerException(ScannerException.disposed);
  }

  /// Serialises lifecycle commands so e.g. a `stop()` issued during `start()`
  /// runs after it instead of racing it.
  Future<T> _enqueue<T>(Future<T> Function() op) {
    final next = _queue.then((_) => op());
    _queue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiobuy_scanner/hiobuy_scanner.dart';

/// Stand-in for the native engine.
class FakeEngine {
  final List<MethodCall> calls = [];
  String permission = 'granted';
  String permissionAfterRequest = 'granted';
  PlatformException? startError;
  MockStreamHandlerEventSink? sink;
  int listenCount = 0;
  int cancelCount = 0;

  List<String> get methods => [for (final c in calls) c.method];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'getPermission':
        return permission;
      case 'requestPermission':
        permission = permissionAfterRequest;
        return permission;
      case 'start':
        if (startError != null) throw startError!;
        return {
          'textureId': 7,
          'previewWidth': 720.0,
          'previewHeight': 1280.0,
          'hasTorch': true,
          'warm': false,
          'sessionReadyMs': 180.0,
        };
      case 'setTorch':
        return (call.arguments as Map)['on'];
      case 'getStats':
        return {'framesAnalyzed': 100, 'detections': 20, 'emitted': 3, 'duplicatesSuppressed': 17, 'outsideRegion': 0};
      case 'openAppSettings':
        return true;
      default:
        return null;
    }
  }

  void emitResult(String value, {int sequence = 1, String format = 'code128'}) {
    sink!.success({
      'type': 'result',
      'value': value,
      'format': format,
      'sequence': sequence,
      'platform': 'android',
      'emitEpochUs': DateTime.now().microsecondsSinceEpoch,
      'frameAgeMs': 12.5,
      'decodeMs': 18.0,
      'nativeTotalMs': 31.0,
      'box': [0.1, 0.4, 0.9, 0.6],
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FakeEngine engine;
  final controllers = <ScannerController>[];

  ScannerController make([ScannerConfig config = const ScannerConfig()]) {
    final c = ScannerController(config: config);
    controllers.add(c);
    return c;
  }

  setUp(() {
    engine = FakeEngine();
    messenger.setMockMethodCallHandler(ScannerController.methodChannel, engine.handle);
    messenger.setMockStreamHandler(
      ScannerController.eventChannel,
      MockStreamHandler.inline(
        onListen: (args, sink) {
          engine.listenCount++;
          engine.sink = sink;
        },
        onCancel: (args) {
          engine.cancelCount++;
          engine.sink = null;
        },
      ),
    );
  });

  tearDown(() async {
    for (final c in controllers) {
      await c.dispose();
    }
    controllers.clear();
    messenger.setMockMethodCallHandler(ScannerController.methodChannel, null);
    messenger.setMockStreamHandler(ScannerController.eventChannel, null);
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  group('config', () {
    test('defaults favour warehouse 1D formats in continuous mode', () {
      const c = ScannerConfig();
      expect(c.mode, ScanMode.continuous);
      expect(c.formats, isNot(contains(BarcodeFormat.qr)));
      expect(c.formats, contains(BarcodeFormat.code128));
      expect(c.dedupeWindow, greaterThan(Duration.zero));
    });

    test('serialises every field', () {
      final m = const ScannerConfig(
        mode: ScanMode.single,
        formats: {BarcodeFormat.qr, BarcodeFormat.itf},
        dedupeWindow: Duration(seconds: 2),
        scanRegion: Rect.fromLTRB(0.1, 0.3, 0.9, 0.6),
        feedback: ScanFeedback(vibrate: false, beep: true),
        resolution: ScanResolution.fhd1080,
        zoom: 2,
        autoZoom: false,
        fastAcceptPatterns: [r'JT\d{13}'],
        labelHold: Duration(milliseconds: 250),
      ).toMap();
      expect(m['mode'], 'single');
      expect(m['formats'], ['qr', 'itf']);
      expect(m['dedupeWindowMs'], 2000);
      expect(m['region'], [0.1, 0.3, 0.9, 0.6]);
      expect(m['vibrate'], false);
      expect(m['beep'], true);
      expect(m['resolution'], 'fhd1080');
      expect(m['zoom'], 2.0);
      expect(m['autoZoom'], false);
      expect(const ScannerConfig().toMap()['autoZoom'], true);
      expect(const ScannerConfig().toMap()['confirmations'], 2);
      expect(m['fastAcceptPatterns'], [r'JT\d{13}']);
      expect(m['labelHoldMs'], 250);
      expect(const ScannerConfig().toMap()['fastAcceptPatterns'], isEmpty);
      expect(const ScannerConfig().toMap()['labelHoldMs'], 400);
      expect(const ScannerConfig().copyWith(confirmations: 1).toMap()['confirmations'], 1);
    });

    test('copyWith can clear nullable fields', () {
      const c = ScannerConfig(scanRegion: Rect.fromLTRB(0, 0, 1, 1), zoom: 2);
      expect(c.copyWith(clearScanRegion: true).scanRegion, isNull);
      expect(c.copyWith(clearZoom: true).zoom, isNull);
      expect(c.copyWith(mode: ScanMode.single).zoom, 2);
    });
  });

  group('ScanResult.fromEvent', () {
    test('parses a full event and computes delivery time', () {
      final r = ScanResult.fromEvent({
        'value': 'ABC',
        'format': 'ean13',
        'sequence': 4,
        'platform': 'ios',
        'emitEpochUs': 1000000,
        'nativeTotalMs': 40,
        'box': [0, 0.25, 1, 0.75],
      }, receivedAtUs: 1002500)!;
      expect(r.value, 'ABC');
      expect(r.format, BarcodeFormat.ean13);
      expect(r.sequence, 4);
      expect(r.platform, 'ios');
      expect(r.timings.dartDeliveryMs, 2.5);
      expect(r.timings.decodeMs, isNull);
      expect(r.timings.nativeTotalMs, 40);
      expect(r.boundingBox, const Rect.fromLTRB(0, 0.25, 1, 0.75));
    });

    test('rejects malformed events', () {
      expect(ScanResult.fromEvent({'value': 'x', 'format': 'pdf417'}, receivedAtUs: 0), isNull);
      expect(ScanResult.fromEvent({'format': 'qr'}, receivedAtUs: 0), isNull);
    });
  });

  group('lifecycle', () {
    test('start requests permission when undetermined, then runs', () async {
      engine.permission = 'denied';
      final c = make();
      await c.start();
      expect(engine.methods, ['getPermission', 'requestPermission', 'start']);
      expect(c.state.value.status, ScannerStatus.running);
      expect(c.state.value.textureId, 7);
      expect(c.state.value.previewSize, const Size(720, 1280));
      expect(c.state.value.hasTorch, isTrue);
      expect(c.state.value.startup!.sessionReadyMs, 180);
    });

    test('start fails without touching the camera when permission is refused', () async {
      engine.permission = 'denied';
      engine.permissionAfterRequest = 'permanentlyDenied';
      final c = make();
      await expectLater(
        c.start(),
        throwsA(isA<ScannerException>().having((e) => e.code, 'code', ScannerException.permissionDenied)),
      );
      expect(engine.methods, isNot(contains('start')));
      expect(c.state.value.status, ScannerStatus.error);
      expect(c.state.value.permission, CameraPermission.permanentlyDenied);
    });

    test('permission can be recovered after a refusal', () async {
      engine.permission = 'permanentlyDenied';
      final c = make();
      await expectLater(c.start(), throwsA(isA<ScannerException>()));
      engine.permission = 'granted'; // user enabled it in settings
      await c.start();
      expect(c.state.value.status, ScannerStatus.running);
      expect(c.state.value.error, isNull);
    });

    test('native start failure surfaces as ScannerException and error state', () async {
      engine.startError = PlatformException(code: 'camera_unavailable', message: 'in use');
      final c = make();
      await expectLater(
        c.start(),
        throwsA(isA<ScannerException>().having((e) => e.code, 'code', 'camera_unavailable')),
      );
      expect(c.state.value.status, ScannerStatus.error);
      engine.startError = null;
      await c.start();
      expect(c.state.value.status, ScannerStatus.running);
    });

    test('start is idempotent while running', () async {
      final c = make();
      await c.start();
      await c.start();
      expect(engine.methods.where((m) => m == 'start'), hasLength(1));
    });

    test('pause levels, resume and stop map to distinct native calls', () async {
      final c = make();
      await c.start();
      await c.pause();
      expect(c.state.value.status, ScannerStatus.paused);
      expect(c.state.value.pauseLevel, PauseLevel.results);
      await c.pause(PauseLevel.analysis);
      expect(c.state.value.pauseLevel, PauseLevel.analysis);
      await c.resume();
      expect(c.state.value.status, ScannerStatus.running);
      expect(c.state.value.pauseLevel, isNull);
      await c.stop();
      expect(c.state.value.status, ScannerStatus.stopped);
      final levels = [
        for (final call in engine.calls)
          if (call.method == 'pause') (call.arguments as Map)['level']
      ];
      expect(levels, ['results', 'analysis']);
      expect(engine.methods.sublist(2), ['pause', 'pause', 'resume', 'stop']);
    });

    test('commands issued concurrently run in order', () async {
      final c = make();
      final f1 = c.start();
      final f2 = c.pause();
      final f3 = c.stop();
      await Future.wait([f1, f2, f3]);
      expect(engine.methods, ['getPermission', 'start', 'pause', 'stop']);
      expect(c.state.value.status, ScannerStatus.stopped);
    });

    test('camera commands are ignored when the camera is not active', () async {
      final c = make();
      await c.pause();
      await c.resume();
      await c.setTorch(true);
      await c.focusAt(const Offset(0.5, 0.5));
      await c.resetDedupe();
      await c.stop();
      expect(engine.calls, isEmpty);
    });

    test('starting a second controller takes the camera from the first', () async {
      final a = make();
      final b = make();
      await a.start();
      await b.start();
      expect(a.state.value.status, ScannerStatus.stopped);
      expect(b.state.value.status, ScannerStatus.running);
      final got = <String>[];
      a.results.listen((r) => got.add('a:${r.value}'));
      b.results.listen((r) => got.add('b:${r.value}'));
      engine.emitResult('X');
      await pump();
      expect(got, ['b:X']);
    });

    test('dispose releases native resources and the event subscription', () async {
      final c = make();
      await c.start();
      await c.dispose();
      expect(engine.methods.last, 'dispose');
      expect(engine.cancelCount, 1);
      expect(c.isDisposed, isTrue);
      await c.dispose(); // idempotent
      expect(engine.methods.where((m) => m == 'dispose'), hasLength(1));
      expect(c.start(), throwsA(isA<ScannerException>()));
    });

    test('dispose of an inactive controller does not kill the active one', () async {
      final a = make();
      final b = make();
      await a.start();
      await b.start();
      await a.dispose();
      expect(engine.methods, isNot(contains('dispose')));
      expect(b.state.value.status, ScannerStatus.running);
    });
  });

  group('events', () {
    test('results are delivered with timings', () async {
      final c = make();
      await c.start();
      final got = <ScanResult>[];
      c.results.listen(got.add);
      engine.emitResult('PKG-001', sequence: 3);
      await pump();
      expect(got.single.value, 'PKG-001');
      expect(got.single.sequence, 3);
      expect(got.single.timings.decodeMs, 18);
      expect(got.single.timings.dartDeliveryMs, greaterThanOrEqualTo(0));
    });

    test('single mode mirrors the native pause before listeners run', () async {
      final c = make(const ScannerConfig(mode: ScanMode.single));
      await c.start();
      ScannerStatus? seen;
      c.results.listen((_) => seen = c.state.value.status);
      engine.emitResult('ONE');
      await pump();
      expect(seen, ScannerStatus.paused);
      expect(c.state.value.pauseLevel, PauseLevel.results);
      await c.resume();
      expect(c.state.value.status, ScannerStatus.running);
    });

    test('native state, torch, first-frame and error events update state', () async {
      final c = make();
      await c.start();
      engine.sink!.success({'type': 'firstFrame', 'sinceStartMs': 240.0});
      engine.sink!.success({'type': 'torch', 'on': true});
      await pump();
      expect(c.state.value.startup!.firstFrameMs, 240);
      expect(c.state.value.torchOn, isTrue);

      engine.sink!.success({'type': 'state', 'state': 'stopped'}); // app backgrounded
      await pump();
      expect(c.state.value.status, ScannerStatus.stopped);
      expect(c.state.value.torchOn, isFalse);

      engine.sink!.success({'type': 'state', 'state': 'running'}); // foregrounded
      await pump();
      expect(c.state.value.status, ScannerStatus.running);

      engine.sink!.success({'type': 'error', 'code': 'camera_error', 'message': 'boom', 'fatal': true});
      await pump();
      expect(c.state.value.status, ScannerStatus.error);
      expect(c.state.value.error!.message, 'boom');
    });

    test('malformed events are ignored', () async {
      final c = make();
      await c.start();
      final got = <ScanResult>[];
      c.results.listen(got.add);
      engine.sink!.success('garbage');
      engine.sink!.success({'type': 'result', 'value': 1});
      engine.sink!.success({'type': 'unknown'});
      await pump();
      expect(got, isEmpty);
      expect(c.state.value.status, ScannerStatus.running);
    });
  });

  group('onScan backpressure', () {
    test('drop: results arriving while the handler is busy are discarded', () async {
      final c = make();
      await c.start();
      final handled = <String>[];
      final gate = Completer<void>();
      c.onScan((r) async {
        handled.add(r.value);
        await gate.future;
      });
      engine.emitResult('A');
      await pump();
      engine.emitResult('B');
      engine.emitResult('C');
      await pump();
      gate.complete();
      await pump();
      expect(handled, ['A']);
      expect((await c.getStats()).droppedWhileBusy, 2);
      engine.emitResult('D');
      await pump();
      expect(handled, ['A', 'D']);
    });

    test('keepLatest: holds at most one pending result', () async {
      final c = make();
      await c.start();
      final handled = <String>[];
      var gate = Completer<void>();
      c.onScan((r) async {
        handled.add(r.value);
        await gate.future;
      }, busyPolicy: BusyPolicy.keepLatest);
      engine.emitResult('A');
      await pump();
      engine.emitResult('B');
      engine.emitResult('C');
      engine.emitResult('D');
      await pump();
      final first = gate;
      gate = Completer<void>()..complete();
      first.complete();
      await pump();
      await pump();
      expect(handled, ['A', 'D']);
      expect((await c.getStats()).droppedWhileBusy, 2);
    });

    test('a throwing handler does not stop later results', () async {
      final c = make();
      await c.start();
      final errors = <Object>[];
      final handled = <String>[];
      c.onScan((r) {
        handled.add(r.value);
        if (r.value == 'BAD') throw StateError('x');
      }, onError: (e, _) => errors.add(e));
      engine.emitResult('BAD');
      await pump();
      engine.emitResult('OK');
      await pump();
      expect(handled, ['BAD', 'OK']);
      expect(errors, hasLength(1));
    });
  });

  group('ScannerView.imageRectToView', () {
    test('same aspect ratio scales directly', () {
      final r = ScannerView.imageRectToView(
        const Rect.fromLTRB(0.25, 0.5, 0.75, 0.6),
        const Size(1080, 1920),
        const Size(360, 640),
      );
      expect(r, const Rect.fromLTRB(90, 320, 270, 384));
    });

    test('taller view crops the image sides', () {
      // 9:16 image in a 360x800 view: shown 450 wide, 45 px cropped each side.
      final r = ScannerView.imageRectToView(
        const Rect.fromLTRB(0.5, 0.5, 1.0, 1.0),
        const Size(1080, 1920),
        const Size(360, 800),
      );
      expect(r, const Rect.fromLTRB(180, 400, 405, 800));
    });

    test('unknown image size falls back to view fractions', () {
      final r = ScannerView.imageRectToView(const Rect.fromLTRB(0, 0, 0.5, 0.5), Size.zero, const Size(200, 400));
      expect(r, const Rect.fromLTRB(0, 0, 100, 200));
    });
  });

  test('stats merge native counters with Dart-side drops', () async {
    final c = make();
    await c.start();
    final s = await c.getStats();
    expect(s.framesAnalyzed, 100);
    expect(s.duplicatesSuppressed, 17);
    expect(s.emitted, 3);
  });

  test('focusAt clamps coordinates and sends the view size', () async {
    final c = make();
    c.attachViewSize(const Size(400, 800));
    await c.start();
    await c.focusAt(const Offset(1.4, -0.2));
    final args = engine.calls.last.arguments as Map;
    expect(args['x'], 1.0);
    expect(args['y'], 0.0);
    expect(args['viewWidth'], 400.0);
    expect(args['viewHeight'], 800.0);
    final startArgs = engine.calls.firstWhere((c) => c.method == 'start').arguments as Map;
    expect(startArgs['viewWidth'], 400.0);
  });
}

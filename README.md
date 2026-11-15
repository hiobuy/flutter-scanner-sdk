# hiobuy_scanner

A fast native barcode scanning engine for Flutter, built for warehouse and logistics work where an operator scans parcel after parcel.

面向仓库连续扫码场景的高性能 Flutter 原生扫码引擎（Android / iOS）。

- **The camera stays open.** Consecutive scans never restart the camera; stopping and starting again is a warm start.
- **Native end to end.** Frames are decoded natively and never cross into Dart. Mode gating, de-duplication and haptic/audio feedback also run natively, so the operator gets feedback before Dart is involved.
- **Point roughly, from arm's length.** Whole-frame detection picks the code nearest the centre; on Android the camera zooms in automatically when a code is too small to read.
- **No Google Play services required.** Android uses the bundled ML Kit model.

| | Android | iOS |
|---|---|---|
| Camera | CameraX (`Preview` + `ImageAnalysis`) | `AVCaptureSession` |
| Decoder | ML Kit Barcode Scanning (bundled) | `AVCaptureMetadataOutput` |
| Preview | Flutter `Texture` | `AVCaptureVideoPreviewLayer` in a platform view |
| Minimum OS | API 24 | iOS 13 |

Formats: Code 128, Code 39, EAN-13, EAN-8, ITF, QR. UPC-A is reported as EAN-13 with a leading `0` on both platforms.

> **Status: early.** Both platforms scan on real devices and the API may still change. See [Known limitations](#known-limitations).

## Install

```yaml
dependencies:
  hiobuy_scanner:
    git:
      url: https://github.com/hiobuy/flutter-scanner-sdk.git
```

The SDK constraint allows Flutter 3.19 and later. Development and testing so far have been on Flutter 3.38.

**iOS** — add to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>The camera is used to scan barcodes.</string>
```

**Android** — nothing to add; the `CAMERA` and `VIBRATE` permissions are merged from the plugin manifest. The bundled ML Kit model adds roughly 2–3 MB per ABI.

## Usage

```dart
import 'package:hiobuy_scanner/hiobuy_scanner.dart';

final controller = ScannerController(
  config: const ScannerConfig(mode: ScanMode.continuous),
);

// Runs the handler for each result, never concurrently.
controller.onScan((result) async {
  await submit(result.value);
});

await controller.start(); // asks for camera permission if needed

// In the widget tree:
ScannerView(controller: controller);

// When the screen goes away:
await controller.dispose();
```

### Scan modes

| Mode | Behaviour |
|---|---|
| `ScanMode.continuous` | Keeps reporting codes. A code held in view is reported once. |
| `ScanMode.single` | Reports one code, then stops accepting results until `controller.resume()`. The camera keeps running. |

### Pausing

Three levels, so you never pay for more of a restart than you need:

| Call | Stops | Cost to resume |
|---|---|---|
| `pause()` | Result delivery only | None |
| `pause(PauseLevel.analysis)` | Frame analysis; preview continues | One frame |
| `stop()` | The camera; configuration is kept | Warm start |
| `dispose()` | Everything | Cold start |

### De-duplication

A value is not reported again while it keeps being seen. It becomes reportable again once it has been out of view for `dedupeWindow` (default 1.5 s), or immediately after `controller.resetDedupe()`. Memory is bounded, so no value is ever blocked permanently.

This is a convenience for the operator. **It is not a substitute for server-side idempotency.**

### Backpressure

`controller.results` is an unbuffered broadcast stream. `controller.onScan` adds a policy for slow handlers: results that arrive while the handler is still running are dropped (`BusyPolicy.drop`, the default) or reduced to the newest one (`BusyPolicy.keepLatest`). At most one result is ever held, and dropped results are counted in `getStats()`.

### Configuration

| `ScannerConfig` field | Default | Notes |
|---|---|---|
| `mode` | `continuous` | |
| `formats` | 1D set (no QR) | Fewer formats decode faster. Use `BarcodeFormat.all` to include QR. |
| `dedupeWindow` | 1.5 s | `Duration.zero` disables de-duplication. |
| `scanRegion` | `null` (whole view) | A `Rect` in fractions of the `ScannerView`. |
| `feedback` | vibrate | `ScanFeedback(vibrate:, beep:)`, produced natively. |
| `resolution` | `hd720` | `sd540`, `hd720`, `fhd1080`. Higher is not always faster. |
| `zoom` | `null` (automatic) | Fixed zoom ratio. |
| `autoZoom` | `true` | Android only. Zooms in on codes too small to decode. |
| `confirmations` | `2` | Android only. Consecutive frames that must agree; see below. |

`controller.updateConfig(...)` applies changes without restarting the camera, except for `resolution`.

Other controls: `setTorch`, `toggleTorch`, `focusAt`, `getPermission`, `requestPermission`, `openAppSettings`, `getStats`. `controller.state` is a `ValueListenable<ScannerState>`.

### Misread protection (Android)

ML Kit occasionally decodes a blurred or partly visible 1D barcode into garbage. With `confirmations: 2` a value is reported only once two consecutive frames agree, which a misread almost never does. It costs one extra frame in the best case and longer when the image is still settling. Set it to `1` to report the first decode.

## Timing

Every `ScanResult` carries its timing as separate segments, because decoder time alone is not what the operator waits for:

| Field | Meaning |
|---|---|
| `frameAgeMs` | Frame captured → analysis started (Android) |
| `decodeMs` | Time in the decoder (Android) |
| `nativeTotalMs` | Frame captured → result produced natively |
| `dartDeliveryMs` | Result produced natively → received in Dart |

None of these include the time before a decodable frame exists: aiming, focusing, motion blur. That has to be measured externally, for example by filming the device with a second phone at 240 fps. See [docs/architecture.md](docs/architecture.md#measuring-latency).

Early numbers from the example app, 20 scans each of real parcel labels, hand-held. They are a first look, not a benchmark:

| Device | `nativeTotalMs` median | Range | `dartDeliveryMs` median |
|---|---|---|---|
| iPhone (iOS 26) | 33 | 30–35 | 0.8 |
| Redmi K40S (Android), `confirmations: 1` | 99 | 79–122 | — |
| Redmi K40S (Android), `confirmations: 2` | 148 | 102–345 | 1.0 |

In the `confirmations: 1` run, one of the 20 results was a misread.

## Example app

```bash
cd example
flutter run --release
```

The example is a test bench: mode switch, format selection, resolution, zoom, torch, tap to focus, per-scan timings, P50/P95, duplicate counters, history, and CSV export to the clipboard.

To run on a physical iPhone, set your signing team in Xcode, or create `example/ios/Flutter/Local.xcconfig` (git-ignored) containing:

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

## Tests

```bash
flutter test                                   # Dart
cd example/android && ./gradlew :hiobuy_scanner:testDebugUnitTest   # Android, needs JDK 17
```

## Known limitations

- Android preview orientation is only handled for portrait.
- Auto-zoom is Android only: the iOS system decoder reports nothing until a code is fully decoded, so there is nothing to zoom towards.
- iOS has no multi-frame confirmation; the system decoder validates internally and no misreads have been observed so far.
- No iOS native unit tests yet.
- Tested on a small number of devices.

## Documentation

- [Architecture and measurement method](docs/architecture.md)

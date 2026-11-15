# Architecture

## Goal

Minimise the time an operator waits between pointing the phone at a label and getting feedback. Most of that time is not decoding. It is opening the camera, focusing, and aiming. The design follows from that:

1. Keep the camera running between scans.
2. Decide and give feedback natively, without waiting for Dart.
3. Make aiming unnecessary where possible (whole-frame detection, auto-zoom).

## Layout

```
Dart      ScannerView          ScannerController            ScanResult
          (preview, gestures)  (state, config, streams)
             │                      │
             │ Texture / UiKitView  │ MethodChannel (commands) + EventChannel (events)
             │                      │
Native    ScannerEngine — one per platform, same behaviour
          camera → frames → decode → region filter → confirmation (Android)
                 → mode gate + de-duplication → feedback → event to Dart
```

A single plugin package; no federated split. The channel surface is small (about a dozen methods and four event types) and hand-written.

Only one controller owns the camera at a time. Starting a controller takes the camera from whichever one had it.

## What runs where

| Step | Where | Why |
|---|---|---|
| Decoding | Native | Frames never cross the channel. |
| Scan-mode gating, de-duplication | Native (`ResultGate`) | Dart only sees results the app should act on. |
| Vibration, beep | Native, own thread | Feedback is not delayed by Dart or by the result path. |
| Slow-handler policy | Dart (`onScan`) | It depends on the app's own futures. |

`ResultGate` is implemented twice (`ResultGate.kt`, `ResultGate.swift`) and must behave identically. The Kotlin version has unit tests.

## Android

- CameraX `Preview` and `ImageAnalysis`, bound to a lifecycle the engine owns rather than to the activity. `stop()` moves it to `CREATED`, which closes the camera but keeps the use cases bound, so the next `start()` is warm.
- `ImageAnalysis` uses `STRATEGY_KEEP_ONLY_LATEST` and `YUV_420_888`. Frames are wrapped with `InputImage.fromMediaImage`, with no copy or conversion. Each `ImageProxy` is closed in the ML Kit task's completion listener, which runs on success, failure and cancellation.
- ML Kit Barcode Scanning with the bundled model, so devices without Google Play services work.
- Auto-zoom uses ML Kit's zoom suggestions. When a code is located but too small to decode, the engine sets the suggested zoom ratio (capped at 5×) and returns to the configured zoom after 1.5 s without needing it.
- Multi-frame confirmation: a value is offered to the gate only after `confirmations` consecutive sightings no more than 300 ms apart. Values matching `fastAcceptPatterns` skip this.
- ML Kit has no region of interest, so `scanRegion` is applied by filtering results on the centre of their bounding box.
- The host activity's lifecycle is observed: the camera is released in the background and reopened in the foreground if it was running.

Threads: main (all CameraX calls), an analysis executor (frames in), a result executor (ML Kit callbacks, filtering, gating), and a feedback executor.

## iOS

- `AVCaptureSession` with `AVCaptureMetadataOutput`. All session and device configuration runs on one serial queue; detection callbacks arrive on another.
- The preview is an `AVCaptureVideoPreviewLayer` in a platform view, rendered by the system with no copy.
- `scanRegion` maps to `rectOfInterest` through the preview layer, and is recomputed on layout and rotation.
- Focus: continuous autofocus, smooth autofocus off, near range restriction. Tap to focus returns to continuous autofocus when the scene changes or after 3 s.
- Minimum focus distance: recent wide cameras cannot focus closer than roughly 15–20 cm. When `zoom` is not set, the engine applies a zoom factor (up to 2×) derived from `minimumFocusDistance`, so a typical label fills the frame from a distance the lens can focus at.
- Interruptions (backgrounding, calls, another app using the camera) and media-services resets are observed and reported; the session resumes when it can.

## Pause levels

| Call | Android | iOS |
|---|---|---|
| `pause(results)` | Gate closed; frames still analysed | Gate closed |
| `pause(analysis)` | `clearAnalyzer()` | `metadataObjectTypes = []` |
| `stop()` | Lifecycle → `CREATED` | `stopRunning()`, session kept configured |
| `dispose()` | Unbind, release texture and decoder | Remove inputs and outputs |

## De-duplication

The gate remembers when each value was last *seen*, not last reported. A value held in view is therefore reported once, however long it stays there, and becomes reportable again after a full window out of view. The table is capped at 64 entries and expires by time, so nothing is blocked permanently. In single mode the table keeps refreshing while the gate is closed, so a parcel still under the camera when the app resumes is not reported twice.

## Label hold

The gate also remembers the last reported value and when it was last seen. Any other value is held back until the reported one has been out of view for `labelHold`. Combined with choosing the code nearest the centre in each frame, a camera resting on a label with several barcodes produces one result rather than one per barcode. The cost is that a different code cannot be reported within `labelHold` of the previous one still being visible.

## Measuring latency

"Time from the barcode being clearly in view to the result" cannot be observed from inside the app, because the app does not know a barcode is there until it decodes one. Two kinds of data are kept apart:

1. **In-app segments**, on every result (`ScanResult.timings`). They start at the capture timestamp of the decoded frame. They do not include aiming, focusing or blur.
2. **End-to-end**, sampled externally: film the device with a second phone at 240 fps, capturing both the label coming into view and the on-screen feedback, and count frames (about 4 ms resolution). Only this number describes what the operator waits for.

Camera start-up is reported separately in `ScannerState.startup`: time to a running session and time to the first frame, each marked warm or cold.

On Android the frame timestamp comes from the sensor. Its clock base varies by device; the engine accepts whichever of the two system clocks gives a plausible age and reports `null` otherwise.

## Open questions

- Default analysis resolution per platform. Not yet measured systematically.
- Whether cropping to the scan region before decoding on Android is a net win (fewer pixels, one extra copy).
- Whether Vision on iOS reads difficult codes that `AVCaptureMetadataOutput` misses.
- Android preview rotation in landscape.

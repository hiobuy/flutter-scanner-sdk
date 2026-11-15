## 0.1.0

Initial version.

* Dart API: `ScannerController`, `ScannerView`, `ScannerConfig`, `ScanResult`.
* Single and continuous scan modes, three pause levels, time-window de-duplication, bounded backpressure.
* Android: CameraX + bundled ML Kit, auto-zoom, multi-frame confirmation.
* iOS: AVFoundation metadata output, minimum-focus-distance zoom compensation.
* Example app with per-scan timing, statistics and CSV export.

import AVFoundation
import AudioToolbox
import UIKit

struct EngineError: Error {
  let code: String
  let message: String
}

struct EngineConfig {
  var mode: ResultGate.Mode = .continuous
  var formats: [String] = ["code128", "code39", "ean13", "ean8", "itf"]
  var dedupeWindowMs: Double = 1500
  var labelHoldMs: Double = 400
  /// Fractions of the preview view; nil = whole view.
  var region: CGRect?
  var vibrate = true
  var beep = false
  var resolution = "hd720"
  var zoom: Double?

  init() {}

  init(_ a: [String: Any]) {
    mode = (a["mode"] as? String) == "single" ? .single : .continuous
    if let f = a["formats"] as? [String] { formats = f }
    if let w = a["dedupeWindowMs"] as? NSNumber { dedupeWindowMs = w.doubleValue }
    if let h = a["labelHoldMs"] as? NSNumber { labelHoldMs = h.doubleValue }
    if let r = a["region"] as? [NSNumber], r.count == 4 {
      region = CGRect(
        x: r[0].doubleValue, y: r[1].doubleValue,
        width: r[2].doubleValue - r[0].doubleValue, height: r[3].doubleValue - r[1].doubleValue)
    }
    vibrate = a["vibrate"] as? Bool ?? true
    beep = a["beep"] as? Bool ?? false
    resolution = a["resolution"] as? String ?? "hd720"
    zoom = (a["zoom"] as? NSNumber)?.doubleValue
  }

  var preset: AVCaptureSession.Preset {
    switch resolution {
    case "sd540": return .iFrame960x540
    case "fhd1080": return .hd1920x1080
    default: return .hd1280x720
    }
  }

  var metadataTypes: [AVMetadataObject.ObjectType] {
    var types: [AVMetadataObject.ObjectType] = []
    for f in formats {
      switch f {
      case "code128": types.append(.code128)
      case "code39": types.append(contentsOf: [.code39, .code39Mod43])
      case "ean13": types.append(.ean13)  // AVFoundation reports UPC-A as EAN-13 with a leading 0
      case "ean8": types.append(.ean8)
      case "qr": types.append(.qr)
      case "itf": types.append(contentsOf: [.interleaved2of5, .itf14])
      default: break
      }
    }
    return types
  }

  static func formatName(_ type: AVMetadataObject.ObjectType) -> String? {
    switch type {
    case .code128: return "code128"
    case .code39, .code39Mod43: return "code39"
    case .ean13: return "ean13"
    case .ean8: return "ean8"
    case .qr: return "qr"
    case .interleaved2of5, .itf14: return "itf"
    default: return nil
    }
  }
}

/// Owns the capture session.
///
/// Threads:
/// - `sessionQueue`: every session/device configuration and start/stop call.
/// - `metadataQueue`: detection callbacks → gating → feedback.
/// - main: preview-layer geometry and delivery of events to Flutter.
/// State shared between them lives behind `lock`.
final class ScannerEngine: NSObject {
  let session = AVCaptureSession()

  /// Always invoked on the main thread.
  var onEvent: (([String: Any]) -> Void)?

  private let sessionQueue = DispatchQueue(label: "com.hiobuy.scanner.session")
  private let metadataQueue = DispatchQueue(label: "com.hiobuy.scanner.metadata", qos: .userInteractive)
  private let frameQueue = DispatchQueue(label: "com.hiobuy.scanner.frames")
  private let gate = ResultGate()
  private let metadataOutput = AVCaptureMetadataOutput()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let haptic = UIImpactFeedbackGenerator(style: .heavy)

  // sessionQueue only
  private var device: AVCaptureDevice?
  private var configured = false
  private var shouldRun = false
  private var focusGeneration = 0

  // guarded by `lock`
  private let lock = NSLock()
  private var config = EngineConfig()
  private var pauseLevel: String?
  private var roiCenter = CGPoint(x: 0.5, y: 0.5)
  private var orientation: AVCaptureVideoOrientation = .portrait
  private var awaitingFirstFrame = false
  private var startT0: CFTimeInterval = 0
  private var sequence = 0
  private var detections = 0
  private var emitted = 0
  private var duplicates = 0
  private var heldBack = 0

  private weak var previewView: ScannerPreviewView?

  override init() {
    super.init()
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(wasInterrupted), name: .AVCaptureSessionWasInterrupted, object: session)
    nc.addObserver(self, selector: #selector(interruptionEnded), name: .AVCaptureSessionInterruptionEnded, object: session)
    nc.addObserver(self, selector: #selector(runtimeError), name: .AVCaptureSessionRuntimeError, object: session)
    nc.addObserver(self, selector: #selector(subjectAreaChanged), name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }
    return body()
  }

  // MARK: - Permission

  static func permission() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return "granted"
    case .notDetermined: return "denied"  // the system prompt can still be shown
    case .denied: return "permanentlyDenied"  // iOS never prompts twice
    case .restricted: return "restricted"
    @unknown default: return "denied"
    }
  }

  static func requestPermission(_ completion: @escaping (String) -> Void) {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
      completion(permission())
      return
    }
    AVCaptureDevice.requestAccess(for: .video) { _ in
      DispatchQueue.main.async { completion(permission()) }
    }
  }

  // MARK: - Lifecycle

  func start(config newConfig: EngineConfig, t0: CFTimeInterval, completion: @escaping (Result<[String: Any], EngineError>) -> Void) {
    sessionQueue.async {
      do {
        let warm = self.configured
        let presetChanged = self.locked { self.config.resolution != newConfig.resolution }
        self.locked { self.config = newConfig }
        if !self.configured {
          try self.configureSession()
        } else if presetChanged {
          self.session.beginConfiguration()
          self.applyPreset()
          self.session.commitConfiguration()
        }
        self.applyDeviceTuning()
        self.applyMetadataTypes(paused: false)
        self.gate.configure(mode: newConfig.mode, windowMs: newConfig.dedupeWindowMs, holdMs: newConfig.labelHoldMs)
        self.gate.resetDedupe()
        self.gate.open()
        self.locked {
          self.pauseLevel = nil
          self.sequence = 0
          self.detections = 0
          self.emitted = 0
          self.duplicates = 0
          self.heldBack = 0
          self.awaitingFirstFrame = true
          self.startT0 = t0
        }
        self.shouldRun = true
        self.videoOutput.setSampleBufferDelegate(self, queue: self.frameQueue)
        if !self.session.isRunning { self.session.startRunning() }
        guard self.session.isRunning else {
          throw EngineError(code: "camera_error", message: "Capture session failed to start")
        }
        let readyMs = (CACurrentMediaTime() - t0) * 1000
        let dims = self.device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let hasTorch = self.device?.hasTorch ?? false
        DispatchQueue.main.async {
          self.haptic.prepare()
          self.viewportChanged()
          var r: [String: Any] = ["warm": warm, "sessionReadyMs": readyMs, "hasTorch": hasTorch]
          if let d = dims {
            // Sensor buffers are landscape; report the upright (portrait) size.
            r["previewWidth"] = Double(min(d.width, d.height))
            r["previewHeight"] = Double(max(d.width, d.height))
          }
          completion(.success(r))
        }
      } catch {
        self.shouldRun = false
        let e = error as? EngineError ?? EngineError(code: "camera_error", message: error.localizedDescription)
        DispatchQueue.main.async { completion(.failure(e)) }
      }
    }
  }

  /// Stops the session but keeps inputs and outputs for a warm restart.
  func stop(completion: (() -> Void)? = nil) {
    sessionQueue.async {
      self.shouldRun = false
      self.gate.close()
      if self.session.isRunning { self.session.stopRunning() }
      DispatchQueue.main.async { completion?() }
    }
  }

  func dispose(completion: (() -> Void)? = nil) {
    sessionQueue.async {
      self.shouldRun = false
      self.gate.close()
      if self.session.isRunning { self.session.stopRunning() }
      self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
      self.metadataOutput.setMetadataObjectsDelegate(nil, queue: nil)
      self.session.beginConfiguration()
      self.session.inputs.forEach { self.session.removeInput($0) }
      self.session.outputs.forEach { self.session.removeOutput($0) }
      self.session.commitConfiguration()
      self.device = nil
      self.configured = false
      DispatchQueue.main.async { completion?() }
    }
  }

  func pause(level: String, completion: @escaping () -> Void) {
    gate.close()
    locked { pauseLevel = level }
    sessionQueue.async {
      self.applyMetadataTypes(paused: level == "analysis")
      DispatchQueue.main.async(execute: completion)
    }
  }

  func resume(completion: @escaping () -> Void) {
    locked { pauseLevel = nil }
    sessionQueue.async {
      self.applyMetadataTypes(paused: false)
      self.gate.open()
      DispatchQueue.main.async(execute: completion)
    }
  }

  func updateConfig(_ newConfig: EngineConfig, completion: @escaping () -> Void) {
    sessionQueue.async {
      let old = self.locked { () -> EngineConfig in
        let o = self.config
        self.config = newConfig
        return o
      }
      if old.resolution != newConfig.resolution, self.configured {
        self.session.beginConfiguration()
        self.applyPreset()
        self.session.commitConfiguration()
      }
      if old.zoom != newConfig.zoom { self.applyDeviceTuning() }
      let analysisPaused = self.locked { self.pauseLevel == "analysis" }
      self.applyMetadataTypes(paused: analysisPaused)
      self.gate.configure(mode: newConfig.mode, windowMs: newConfig.dedupeWindowMs, holdMs: newConfig.labelHoldMs)
      if old.mode != newConfig.mode, self.locked({ self.pauseLevel == nil }) { self.gate.open() }
      DispatchQueue.main.async {
        self.applyRegion()
        completion()
      }
    }
  }

  func resetDedupe() { gate.resetDedupe() }

  func stats() -> [String: Any] {
    return locked {
      [
        "framesAnalyzed": 0,
        "detections": detections,
        "emitted": emitted,
        "duplicatesSuppressed": duplicates,
        "heldBack": heldBack,
        "outsideRegion": 0,
      ]
    }
  }

  // MARK: - Camera controls

  func setTorch(_ on: Bool, completion: @escaping (Bool) -> Void) {
    sessionQueue.async {
      var actual = false
      if let d = self.device, d.hasTorch, d.isTorchAvailable, (try? d.lockForConfiguration()) != nil {
        d.torchMode = on ? .on : .off
        d.unlockForConfiguration()
        actual = on
      }
      DispatchQueue.main.async { completion(actual) }
    }
  }

  /// `point` is in fractions of the preview view. Call on the main thread.
  func focus(atViewPoint point: CGPoint) {
    var devicePoint = CGPoint(x: 0.5, y: 0.5)
    if let v = previewView, v.bounds.width > 0 {
      devicePoint = v.previewLayer.captureDevicePointConverted(
        fromLayerPoint: CGPoint(x: point.x * v.bounds.width, y: point.y * v.bounds.height))
    }
    sessionQueue.async {
      guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
      if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
        d.focusPointOfInterest = devicePoint
        d.focusMode = .autoFocus
      }
      if d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.continuousAutoExposure) {
        d.exposurePointOfInterest = devicePoint
        d.exposureMode = .continuousAutoExposure
      }
      d.isSubjectAreaChangeMonitoringEnabled = true
      d.unlockForConfiguration()
      // Return to continuous autofocus when the scene changes, or after 3 s.
      self.focusGeneration += 1
      let generation = self.focusGeneration
      self.sessionQueue.asyncAfter(deadline: .now() + 3) {
        if generation == self.focusGeneration { self.restoreContinuousFocus() }
      }
    }
  }

  // MARK: - Preview

  /// Call on the main thread.
  func attach(preview: ScannerPreviewView) {
    previewView = preview
    preview.previewLayer.session = session
    viewportChanged()
  }

  /// Call on the main thread whenever the preview's size or orientation changes.
  func viewportChanged() {
    if let c = previewView?.previewLayer.connection, c.isVideoOrientationSupported {
      let o = ScannerEngine.currentVideoOrientation()
      c.videoOrientation = o
      locked { orientation = o }
    }
    applyRegion()
  }

  private static func currentVideoOrientation() -> AVCaptureVideoOrientation {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    switch scene?.interfaceOrientation {
    case .landscapeLeft: return .landscapeLeft
    case .landscapeRight: return .landscapeRight
    case .portraitUpsideDown: return .portraitUpsideDown
    default: return .portrait
    }
  }

  /// Translates the configured view region into the metadata output's
  /// coordinate space. Main thread.
  private func applyRegion() {
    let region = locked { config.region }
    var roi = CGRect(x: 0, y: 0, width: 1, height: 1)
    if let region = region, let v = previewView, v.bounds.width > 0, v.bounds.height > 0 {
      let b = v.bounds
      let layerRect = CGRect(
        x: region.minX * b.width, y: region.minY * b.height,
        width: region.width * b.width, height: region.height * b.height)
      let converted = v.previewLayer.metadataOutputRectConverted(fromLayerRect: layerRect)
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      // Zero until the layer has a live connection; fall back to full frame.
      if converted.width > 0.01, converted.height > 0.01 { roi = converted }
    }
    sessionQueue.async {
      guard self.configured else { return }
      self.metadataOutput.rectOfInterest = roi
      self.locked { self.roiCenter = CGPoint(x: roi.midX, y: roi.midY) }
    }
  }

  // MARK: - Session configuration (sessionQueue)

  private func configureSession() throws {
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
      throw EngineError(code: "camera_unavailable", message: "No back camera on this device")
    }
    let input: AVCaptureDeviceInput
    do {
      input = try AVCaptureDeviceInput(device: device)
    } catch {
      throw EngineError(code: "camera_unavailable", message: error.localizedDescription)
    }
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    guard session.canAddInput(input), session.canAddOutput(metadataOutput) else {
      throw EngineError(code: "camera_error", message: "Cannot configure capture session")
    }
    session.addInput(input)
    session.addOutput(metadataOutput)
    metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
    // Used only to timestamp the first frame after start; its delegate is
    // removed again as soon as that frame arrives.
    videoOutput.alwaysDiscardsLateVideoFrames = true
    if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
    self.device = device
    applyPreset()
    configured = true
  }

  private func applyPreset() {
    let preset = locked { config.preset }
    if session.canSetSessionPreset(preset) {
      session.sessionPreset = preset
    } else if session.canSetSessionPreset(.hd1280x720) {
      session.sessionPreset = .hd1280x720
    }
  }

  private func applyMetadataTypes(paused: Bool) {
    guard configured else { return }
    let wanted: [AVMetadataObject.ObjectType] = paused ? [] : locked { config.metadataTypes }
    let available = metadataOutput.availableMetadataObjectTypes
    metadataOutput.metadataObjectTypes = wanted.filter { available.contains($0) }
  }

  private func applyDeviceTuning() {
    guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
    defer { d.unlockForConfiguration() }
    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
    if d.isSmoothAutoFocusSupported { d.isSmoothAutoFocusEnabled = false }  // fastest lens travel
    if d.isAutoFocusRangeRestrictionSupported { d.autoFocusRangeRestriction = .near }
    if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
    let requested = locked { config.zoom }
    let zoom = requested.map { CGFloat($0) } ?? ScannerEngine.recommendedZoom(for: d)
    d.videoZoomFactor = min(max(zoom, d.minAvailableVideoZoomFactor), min(d.maxAvailableVideoZoomFactor, 8))
  }

  /// Recent wide cameras cannot focus closer than ~15–20 cm, so a small label
  /// held close never gets sharp. Zoom in just enough that a typical label
  /// fills the frame from a distance the lens can focus at. (Apple's
  /// recommendation for barcode scanning; values to be tuned in M3.)
  private static func recommendedZoom(for d: AVCaptureDevice) -> CGFloat {
    guard #available(iOS 15.0, *) else { return 1.0 }
    let minFocusMm = CGFloat(d.minimumFocusDistance)
    guard minFocusMm > 0 else { return 1.0 }
    let labelWidthMm: CGFloat = 50
    let fillFraction: CGFloat = 0.8
    let halfFov = CGFloat(d.activeFormat.videoFieldOfView) * .pi / 360
    let distanceToFillMm = (labelWidthMm / fillFraction) / tan(halfFov)
    guard distanceToFillMm > 0, distanceToFillMm < minFocusMm else { return 1.0 }
    return min(minFocusMm / distanceToFillMm, 2.0)
  }

  private func restoreContinuousFocus() {
    guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
    if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
    d.isSubjectAreaChangeMonitoringEnabled = false
    d.unlockForConfiguration()
  }

  // MARK: - Notifications

  @objc private func subjectAreaChanged(_ n: Notification) {
    sessionQueue.async {
      guard (n.object as? AVCaptureDevice) === self.device else { return }
      self.focusGeneration += 1
      self.restoreContinuousFocus()
    }
  }

  @objc private func wasInterrupted(_ n: Notification) {
    // Backgrounding, a phone call, another app taking the camera…
    // The system resumes the session itself; just tell Dart.
    emit(["type": "state", "state": "stopped", "reason": "interrupted"])
    emit(["type": "torch", "on": false])
  }

  @objc private func interruptionEnded(_ n: Notification) {
    sessionQueue.async {
      guard self.shouldRun else { return }
      self.emitCurrentState()
    }
  }

  @objc private func runtimeError(_ n: Notification) {
    let error = n.userInfo?[AVCaptureSessionErrorKey] as? AVError
    sessionQueue.async {
      guard self.shouldRun else { return }
      if error?.code == .mediaServicesWereReset {
        self.session.startRunning()
        if self.session.isRunning {
          self.emitCurrentState()
          return
        }
      }
      self.shouldRun = false
      self.emit([
        "type": "error", "code": "camera_error", "fatal": true,
        "message": error?.localizedDescription ?? "Capture session runtime error",
      ])
    }
  }

  private func emitCurrentState() {
    if let level = locked({ pauseLevel }) {
      emit(["type": "state", "state": "paused", "level": level])
    } else if !gate.isAccepting {
      // Single mode, still waiting for the business layer to resume.
      emit(["type": "state", "state": "paused", "level": "results"])
    } else {
      emit(["type": "state", "state": "running"])
    }
  }

  private func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { self.onEvent?(event) }
  }
}

// MARK: - Detection

extension ScannerEngine: AVCaptureMetadataOutputObjectsDelegate {
  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
    let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
    var best: (code: AVMetadataMachineReadableCodeObject, format: String, value: String)?
    var bestDistance = CGFloat.greatestFiniteMagnitude
    let center = locked { roiCenter }
    for object in objects {
      guard let code = object as? AVMetadataMachineReadableCodeObject,
        let value = code.stringValue, !value.isEmpty,
        let format = EngineConfig.formatName(code.type)
      else { continue }
      let dx = code.bounds.midX - center.x
      let dy = code.bounds.midY - center.y
      let distance = dx * dx + dy * dy
      if distance < bestDistance {
        bestDistance = distance
        best = (code, format, value)
      }
    }
    guard let hit = best else { return }

    let nowMs = CACurrentMediaTime() * 1000
    let decision = gate.offer(hit.value, nowMs: nowMs)
    let (vibrate, beep, seq, upright) = locked { () -> (Bool, Bool, Int, AVCaptureVideoOrientation) in
      detections += 1
      switch decision {
      case .emit:
        emitted += 1
        sequence += 1
      case .duplicate: duplicates += 1
      case .held: heldBack += 1
      case .closed: break
      }
      return (config.vibrate, config.beep, sequence, orientation)
    }
    guard decision == .emit else { return }

    // Feedback first: the operator should not wait for Dart.
    if beep { AudioServicesPlaySystemSound(1057) }
    if vibrate {
      DispatchQueue.main.async {
        self.haptic.impactOccurred()
        self.haptic.prepare()
      }
    }

    // `time` is the capture timestamp of the frame the code was found in.
    let ageMs = CMTimeGetSeconds(CMTimeSubtract(hostNow, hit.code.time)) * 1000
    var event: [String: Any] = [
      "type": "result",
      "value": hit.value,
      "format": hit.format,
      "platform": "ios",
      "sequence": seq,
      "emitEpochUs": Int64(Date().timeIntervalSince1970 * 1_000_000),
      "box": ScannerEngine.uprightBox(hit.code.bounds, upright),
    ]
    if ageMs.isFinite, ageMs >= 0, ageMs < 10_000 { event["nativeTotalMs"] = ageMs }
    emit(event)
  }

  /// Metadata bounds are normalised to the sensor's landscape frame; rotate
  /// them into the upright image the user sees.
  private static func uprightBox(_ b: CGRect, _ o: AVCaptureVideoOrientation) -> [Double] {
    let r: CGRect
    switch o {
    case .portrait: r = CGRect(x: 1 - b.maxY, y: b.minX, width: b.height, height: b.width)
    case .portraitUpsideDown: r = CGRect(x: b.minY, y: 1 - b.maxX, width: b.height, height: b.width)
    case .landscapeLeft: r = CGRect(x: 1 - b.maxX, y: 1 - b.maxY, width: b.width, height: b.height)
    default: r = b
    }
    return [Double(r.minX), Double(r.minY), Double(r.maxX), Double(r.maxY)]
  }
}

extension ScannerEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    let t0 = locked { () -> CFTimeInterval? in
      guard awaitingFirstFrame else { return nil }
      awaitingFirstFrame = false
      return startT0
    }
    guard let start = t0 else { return }
    let ms = (CACurrentMediaTime() - start) * 1000
    emit(["type": "firstFrame", "sinceStartMs": ms])
    // No further frames are needed in the app process.
    sessionQueue.async { self.videoOutput.setSampleBufferDelegate(nil, queue: nil) }
  }
}

/// Hosts the capture preview layer.
final class ScannerPreviewView: UIView {
  var onLayout: (() -> Void)?

  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

  var previewLayer: AVCaptureVideoPreviewLayer {
    // swiftlint:disable:next force_cast
    return layer as! AVCaptureVideoPreviewLayer
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    previewLayer.videoGravity = .resizeAspectFill
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }
}

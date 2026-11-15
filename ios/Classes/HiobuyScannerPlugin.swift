import AVFoundation
import Flutter
import UIKit

public class HiobuyScannerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let engine = ScannerEngine()
  private var eventSink: FlutterEventSink?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = HiobuyScannerPlugin()
    let methods = FlutterMethodChannel(name: "hiobuy_scanner/methods", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(name: "hiobuy_scanner/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    registrar.register(ScannerPreviewFactory(engine: instance.engine), withId: "hiobuy_scanner/preview")
    instance.engine.onEvent = { [weak instance] event in
      instance?.eventSink?(event)
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    eventSink = nil
    engine.dispose()
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let t0 = CACurrentMediaTime()
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "getPermission":
      result(ScannerEngine.permission())
    case "requestPermission":
      ScannerEngine.requestPermission { result($0) }
    case "openAppSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else { return result(false) }
      UIApplication.shared.open(url, options: [:]) { result($0) }
    case "start":
      guard ScannerEngine.permission() == "granted" else {
        return result(FlutterError(code: "permission_denied", message: "Camera permission not granted", details: nil))
      }
      engine.start(config: EngineConfig(args), t0: t0) { outcome in
        switch outcome {
        case .success(let info): result(info)
        case .failure(let e): result(FlutterError(code: e.code, message: e.message, details: nil))
        }
      }
    case "stop":
      engine.stop { result(nil) }
    case "dispose":
      engine.dispose { result(nil) }
    case "pause":
      engine.pause(level: args["level"] as? String ?? "results") { result(nil) }
    case "resume":
      engine.resume { result(nil) }
    case "updateConfig":
      engine.updateConfig(EngineConfig(args)) { result(nil) }
    case "setViewport":
      engine.viewportChanged()
      result(nil)
    case "setTorch":
      engine.setTorch(args["on"] as? Bool ?? false) { result($0) }
    case "focusAt":
      let x = (args["x"] as? NSNumber)?.doubleValue ?? 0.5
      let y = (args["y"] as? NSNumber)?.doubleValue ?? 0.5
      engine.focus(atViewPoint: CGPoint(x: x, y: y))
      result(nil)
    case "resetDedupe":
      engine.resetDedupe()
      result(nil)
    case "getStats":
      result(engine.stats())
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

final class ScannerPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let engine: ScannerEngine

  init(engine: ScannerEngine) {
    self.engine = engine
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    return ScannerPlatformView(frame: frame, engine: engine)
  }
}

final class ScannerPlatformView: NSObject, FlutterPlatformView {
  private let preview: ScannerPreviewView

  init(frame: CGRect, engine: ScannerEngine) {
    preview = ScannerPreviewView(frame: frame)
    super.init()
    preview.onLayout = { [weak engine] in engine?.viewportChanged() }
    engine.attach(preview: preview)
  }

  func view() -> UIView {
    return preview
  }
}

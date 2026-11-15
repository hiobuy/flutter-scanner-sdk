import Foundation

/// Decides which detections become results: scan-mode gating plus
/// time-window de-duplication. Pure logic, safe to call from any thread.
///
/// The Android implementation (`ResultGate.kt`) must behave identically.
final class ResultGate {
  enum Mode { case single, continuous }
  enum Decision: Equatable { case emit, duplicate, closed, held }

  static let maxEntries = 64

  private let lock = NSLock()
  private var mode: Mode = .continuous
  private var windowMs: Double = 1500
  private var accepting = true
  private var holdMs: Double = 0
  private var lastEmitted: String?
  private var lastEmittedSeenMs: Double = 0
  /// value → time it was last seen (not last emitted), in milliseconds.
  private var lastSeen: [String: Double] = [:]

  func configure(mode: Mode, windowMs: Double, holdMs: Double = 0) {
    lock.lock(); defer { lock.unlock() }
    self.mode = mode
    self.windowMs = max(0, windowMs)
    self.holdMs = max(0, holdMs)
  }

  /// Offers a detection made at `nowMs` (any monotonic clock).
  ///
  /// A value is a duplicate while it keeps being seen within the window, so a
  /// barcode held in view is reported once, and reported again only after it
  /// has been out of view for a full window (or after `resetDedupe`).
  ///
  /// Label hold: a label often carries more than one barcode. After a result,
  /// any *other* value is held back until the reported one has been out of
  /// view for `holdMs`, so the camera resting on one label yields one result.
  func offer(_ value: String, nowMs: Double) -> Decision {
    lock.lock(); defer { lock.unlock() }
    if value == lastEmitted {
      lastEmittedSeenMs = nowMs
    } else if holdMs > 0, lastEmitted != nil, nowMs - lastEmittedSeenMs < holdMs {
      return .held
    }
    let seenRecently: Bool
    if windowMs > 0, let last = lastSeen[value], nowMs - last < windowMs {
      seenRecently = true
    } else {
      seenRecently = false
    }
    if windowMs > 0 {
      // Refresh even while closed, so a parcel still under the camera when
      // the business layer resumes is not immediately reported a second time.
      if seenRecently || accepting { remember(value, nowMs) }
    }
    if !accepting { return .closed }
    if seenRecently { return .duplicate }
    if mode == .single { accepting = false }
    lastEmitted = value
    lastEmittedSeenMs = nowMs
    return .emit
  }

  /// Stops accepting results (pause, or after a single-mode result).
  func close() {
    lock.lock(); defer { lock.unlock() }
    accepting = false
  }

  func open() {
    lock.lock(); defer { lock.unlock() }
    accepting = true
  }

  var isAccepting: Bool {
    lock.lock(); defer { lock.unlock() }
    return accepting
  }

  func resetDedupe() {
    lock.lock(); defer { lock.unlock() }
    lastSeen.removeAll()
    lastEmitted = nil
  }

  private func remember(_ value: String, _ nowMs: Double) {
    lastSeen[value] = nowMs
    guard lastSeen.count > ResultGate.maxEntries else { return }
    lastSeen = lastSeen.filter { nowMs - $0.value < windowMs }
    while lastSeen.count > ResultGate.maxEntries {
      if let oldest = lastSeen.min(by: { $0.value < $1.value }) {
        lastSeen.removeValue(forKey: oldest.key)
      }
    }
  }
}

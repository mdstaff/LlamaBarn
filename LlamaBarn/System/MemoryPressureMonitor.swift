import Foundation
import os.log

/// Monitors system memory pressure and unloads the active model on critical events
/// to prevent macOS SSD swap and preserve system responsiveness.
///
/// Lifecycle: start() when llama-server launches, stop() when it stops.
/// Zero overhead during normal operation — kernel push notification, no polling.
@MainActor
final class MemoryPressureMonitor {
  static let shared = MemoryPressureMonitor()

  private var source: DispatchSourceMemoryPressure?
  private var lastCriticalActionDate: Date?
  private let cooldownSeconds: TimeInterval = 60
  private let inflightTimeoutSeconds: TimeInterval = 5
  private let logger = Logger(subsystem: Logging.subsystem, category: "MemoryPressure")

  private init() {}

  func start() {
    guard source == nil else { return }

    let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    src.setEventHandler { [weak self] in
      self?.handlePressureEvent(src.data)
    }
    src.resume()
    source = src
    logger.info("Memory pressure monitor started")
  }

  func stop() {
    source?.cancel()
    source = nil
  }

  private func handlePressureEvent(_ event: DispatchSource.MemoryPressureEvent) {
    switch event {
    case .warning:
      logger.warning("System memory pressure: warning — static mitigations active")

    case .critical:
      let now = Date()
      if let last = lastCriticalActionDate, now.timeIntervalSince(last) < cooldownSeconds {
        logger.warning("System memory pressure: critical (suppressed — within cooldown)")
        return
      }

      logger.error("System memory pressure: critical — will unload active model")
      lastCriticalActionDate = now

      Task {
        await self.handleCriticalPressure()
      }

    default:
      break
    }
  }

  private func handleCriticalPressure() async {
    let server = LlamaServer.shared

    guard let activePath = server.activeModelPath else {
      logger.info("Memory pressure: critical, but no model is loaded — nothing to do")
      return
    }

    // Wait briefly for any in-flight generation to complete before unloading.
    // This preserves the current response in most cases.
    let deadline = Date().addingTimeInterval(inflightTimeoutSeconds)
    while Date() < deadline && server.isAnyModelLoading {
      try? await Task.sleep(nanoseconds: 500_000_000)
    }

    if server.isAnyModelLoading {
      logger.warning("Memory pressure: in-flight generation did not complete within timeout — forcing unload")
    }

    guard let model = Catalog.allModels().first(where: { $0.modelFilePath == activePath }) else {
      logger.error("Memory pressure: could not find catalog entry for active model path")
      return
    }

    NotificationCenter.default.post(name: .LBMemoryPressureDidOccur, object: self)
    server.unloadModel(model)
    logger.info("Unloaded \(model.displayName) due to critical memory pressure")
  }
}

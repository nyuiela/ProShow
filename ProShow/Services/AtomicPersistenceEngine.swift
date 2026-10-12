import Foundation

/// Atomic replace-in-place writes for project manifests, libraries, and prefs JSON.
enum AtomicPersistenceEngine {
    private static let queue = DispatchQueue(label: "com.proshow.persistence.atomic", qos: .utility)
    private static var saveDebounceTimer: DispatchSourceTimer?
    private static var pendingWrite: (() -> Void)?

    static let autoSaveDebounce: TimeInterval = 0.5

    /// Debounced background flush (500 ms) for drag-heavy editors.
    static func scheduleDebouncedWrite(_ block: @escaping () -> Void) {
        queue.async {
            saveDebounceTimer?.cancel()
            pendingWrite = block
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + autoSaveDebounce)
            timer.setEventHandler {
                guard let pending = pendingWrite else { return }
                pendingWrite = nil
                pending()
            }
            timer.resume()
            saveDebounceTimer = timer
        }
    }

    static func writeData(_ data: Data, to targetURL: URL) throws {
        let fileManager = FileManager.default
        let directory = targetURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        if fileManager.fileExists(atPath: targetURL.path) {
            _ = try fileManager.replaceItemAt(targetURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: targetURL)
        }
    }

    static func flushPendingImmediately() {
        queue.sync {
            saveDebounceTimer?.cancel()
            saveDebounceTimer = nil
            pendingWrite?()
            pendingWrite = nil
        }
    }
}

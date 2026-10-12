import Foundation

/// CADisplayLink-driven scroll offsets for jitter-free teleprompter motion.
/// Implementation: milestone 2 (Teleprompter UI).
@MainActor
protocol ScrollEngineProtocol: AnyObject {
    var offset: Double { get }
    var isRunning: Bool { get }
    var speedPointsPerSecond: Double { get set }

    func start()
    func pause()
    func reset()
    func seek(to offset: Double)
}

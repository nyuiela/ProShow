import Foundation

/// Single output state for encode, record, and stream-window preview.
/// Desk playback and editing still run the program clock independently.
enum ProgramOutputMode: Equatable, Sendable, CustomStringConvertible {
    case idle
    case preview(source: PreviewSource)
    case recording(capped: Bool)
    case live(preset: String)
    case liveAndRecording(preset: String)

    enum PreviewSource: Equatable, Sendable {
        case operatorDesk
        case streamWindow
        case multiViewer
    }

    var isLive: Bool {
        switch self {
        case .live, .liveAndRecording: true
        default: false
        }
    }

    var isRecording: Bool {
        switch self {
        case .recording, .liveAndRecording: true
        default: false
        }
    }

    /// Off-screen Core Image composite (canonical encode path).
    var requiresOffScreenComposite: Bool {
        switch self {
        case .idle, .preview(.multiViewer): false
        case .preview(.operatorDesk), .preview(.streamWindow), .recording, .live, .liveAndRecording: true
        }
    }

    var targetFrameRate: Int {
        switch self {
        case .recording: 30
        case .live, .liveAndRecording: 30
        case .preview: 30
        case .idle: 30
        }
    }

    var description: String {
        switch self {
        case .idle: ProShowCopy.Status.off
        case .preview: ProShowCopy.Status.ready
        case .recording: ProShowCopy.Status.recording
        case .live(let preset): ProShowCopy.meta([ProShowCopy.Status.live, preset])
        case .liveAndRecording(let preset): ProShowCopy.meta([ProShowCopy.Status.live, ProShowCopy.Status.recording, preset])
        }
    }
}

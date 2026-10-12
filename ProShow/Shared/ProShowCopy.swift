import Foundation

/// Operator-facing words. Visible strings stay inside the glance budgets.
/// Raw errors, codes, and paths stay out of these strings.
enum ProShowCopy {
    enum Status {
        static var live: String { String(localized: "Live") }
        static var recording: String { String(localized: "Recording") }
        static var ready: String { String(localized: "Ready") }
        static var connecting: String { String(localized: "Connecting") }
        static var paused: String { String(localized: "Paused") }
        static var stopping: String { String(localized: "Stopping") }
        static var sandbox: String { String(localized: "Sandbox") }
        static var sandboxCompact: String { String(localized: "SBX") }
        static var selected: String { String(localized: "Selected") }
        static var synced: String { String(localized: "Synced") }
        static var offline: String { String(localized: "Offline") }
        static var off: String { String(localized: "Off") }
        static var error: String { String(localized: "Error") }
        static var clip: String { String(localized: "Clip") }
    }

    static func meta(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    static func liveClock(_ timecode: String) -> String {
        meta([Status.live, timecode])
    }

    static func issues(_ count: Int) -> String {
        String(format: String(localized: "%lld Issues"), locale: .current, count)
    }

    static func warnings(_ count: Int) -> String {
        String(format: String(localized: "%lld Warnings"), locale: .current, count)
    }

    /// Level-1 message. Callers keep the raw string for the log.
    static func error(for raw: String?) -> String {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return String(localized: "Stream failed. Retry.") }
        let lower = text.lowercased()
        if lower.contains("destination url") || lower.contains("server missing") {
            return String(localized: "Server missing. Add a URL.")
        }
        if lower.contains("stream key") {
            return String(localized: "Stream key missing. Reconnect.")
        }
        if lower.contains("no stream transport") || lower.contains("encoder failed") {
            return String(localized: "Encoder failed. Retry.")
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return String(localized: "Ingest timed out. Retry.")
        }
        if lower.contains("dropped") || lower.contains("connection was lost") {
            return String(localized: "Ingest dropped. Retry.")
        }
        if lower.contains("not on air") || lower.contains("could not reach") || lower.contains("unreachable") || lower.contains("-1004") {
            return String(localized: "Ingest unreachable. Check network.")
        }
        if lower.contains("pre-flight") || lower.contains("preflight") || lower.contains("blocking") {
            return String(localized: "Blocking issues. Open Pre-Flight.")
        }
        if lower.contains("select at least") || lower.contains("select a destination") || lower.contains("choose a destination") {
            return String(localized: "Choose a destination.")
        }
        if lower.contains("disk") || lower.contains("no space") {
            return String(localized: "Disk is full.")
        }
        if lower.contains("permission") || lower.contains("not authorized") || lower.contains("access needed") {
            return String(localized: "Access needed. Open Settings.")
        }
        if lower.contains("sign-in") || lower.contains("sign in") || lower.contains("oauth") {
            return String(localized: "Sign-in failed. Check the redirect.")
        }
        if text.count <= 42,
           !text.contains("/"),
           !lower.contains("nserror"),
           !lower.contains("error domain"),
           !lower.contains("http ") {
            return text
        }
        return String(localized: "Action failed. Show Log.")
    }
}

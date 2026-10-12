import Foundation

/// Parses script body into timed `SpokenWord` units (vocal tags + punctuation pacing).
enum ScriptTokenizer {
    /// `[TAG]`, `[/TAG]`, `[LONG PAUSE]`, `[PAUSE:5]`, `[PAUSE:5s]`, `[LONGPAUSE:12.5s]`
    /// Optional leading `/` closes a style span (HTML-style `[/HEAVY]` → reset to normal).
    private static let tagPattern = #"\[(/?)([A-Za-z]+(?:\s+[A-Za-z]+)*)(?::\s*(\d+(?:\.\d+)?)\s*s?)?\]"#

    /// `[JOIN]…[/JOIN]` (aliases `PHRASE`, `BUNDLE`) — one kinetic unit with spaces preserved.
    private static let joinPattern = #"(?is)\[(JOIN|PHRASE|BUNDLE)\](.*?)\[/(JOIN|PHRASE|BUNDLE)\]"#

    /// Internal glue so spaces inside a join survive `appendPlain` whitespace splitting.
    static let joinGlue: Character = "\u{001F}"

    static func tokenize(
        _ body: String,
        baseWPM: Int = 150,
        pacing: ScriptPacing = .default
    ) -> [SpokenWord] {
        let wpm = max(60, min(240, baseWPM))
        let secondsPerWord = 60.0 / Double(wpm)
        // Preserve author line breaks; normalize Windows / old-Mac newlines first.
        let normalized = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let withJoins = expandJoinMarkup(normalized)

        var style: VocalStyle = .normal
        var words: [SpokenWord] = []

        let nsBody = withJoins as NSString
        let full = NSRange(location: 0, length: nsBody.length)
        guard let regex = try? NSRegularExpression(pattern: tagPattern) else {
            appendPlain(withJoins, style: .normal, secondsPerWord: secondsPerWord, pacing: pacing, into: &words)
            return words
        }

        var cursor = 0
        for match in regex.matches(in: withJoins, range: full) {
            let tagRange = match.range(at: 0)
            if tagRange.location > cursor {
                let slice = nsBody.substring(with: NSRange(location: cursor, length: tagRange.location - cursor))
                appendPlain(slice, style: style, secondsPerWord: secondsPerWord, pacing: pacing, into: &words)
            }

            let isClose: Bool = {
                let slashRange = match.range(at: 1)
                guard slashRange.location != NSNotFound, slashRange.length > 0 else { return false }
                return nsBody.substring(with: slashRange) == "/"
            }()
            let name = nsBody.substring(with: match.range(at: 2))
                .uppercased()
                .replacingOccurrences(of: " ", with: "")
            let explicitSeconds: TimeInterval? = {
                let range = match.range(at: 3)
                guard range.location != NSNotFound else { return nil }
                return TimeInterval(nsBody.substring(with: range))
            }()

            if name == "PAUSE" || name == "LONGPAUSE" {
                // Closing `[/PAUSE]` is noise — ignore rather than inserting a hold.
                guard !isClose else {
                    cursor = tagRange.location + tagRange.length
                    continue
                }
                let pause = makePause(name: name, explicitSeconds: explicitSeconds, pacing: pacing)
                // Collapse accidental double tags (`[LONGPAUSE][LONGPAUSE]`) into one hold.
                if pause.isLongPause, let last = words.last, last.isLongPause {
                    words[words.count - 1] = SpokenWord(
                        id: last.id,
                        text: "",
                        characterCount: 0,
                        punctuationPause: max(last.punctuationPause, pause.punctuationPause),
                        vocalStyle: .normal,
                        baseDuration: 0,
                        lineBreaksAfter: last.lineBreaksAfter,
                        lineBreakHold: last.lineBreakHold,
                        pauseKind: .long
                    )
                } else {
                    words.append(pause)
                }
            } else if VocalStyle.resolve(tag: name) != nil {
                // Open applies style; HTML-style closer resets (same as `[NORMAL]`).
                style = isClose ? .normal : (VocalStyle.resolve(tag: name) ?? .normal)
            }
            cursor = tagRange.location + tagRange.length
        }

        if cursor < nsBody.length {
            let slice = nsBody.substring(from: cursor)
            appendPlain(slice, style: style, secondsPerWord: secondsPerWord, pacing: pacing, into: &words)
        }

        return words
    }

    /// Replaces `[JOIN]a b[/JOIN]` with a single glued token (`a␟b`).
    static func expandJoinMarkup(_ body: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: joinPattern) else { return body }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return body }

        var result = body
        for match in matches.reversed() {
            let inner = ns.substring(with: match.range(at: 2))
            let glued = gluePhrase(inner)
            guard !glued.isEmpty else {
                result = (result as NSString).replacingCharacters(in: match.range, with: "")
                continue
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: glued)
        }
        return result
    }

    /// Collapse whitespace and glue words with `joinGlue` (also used by `_` tokenization).
    static func gluePhrase(_ raw: String) -> String {
        let parts = raw
            .split { $0.isWhitespace || $0.isNewline }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: String(joinGlue))
    }

    /// Display text for a token that may contain join glue or underscore markers.
    static func displayText(for token: String) -> String {
        let spaced = token.replacingOccurrences(of: String(joinGlue), with: " ")
        // Underscores inside a website stay put (`stellar.org/a_b`). Phrase glue still becomes spaces.
        if spaced.contains("://") || spaced.contains("/") || PromptWebsiteURL.canonical(spaced) != nil {
            return spaced
        }
        return spaced.replacingOccurrences(of: "_", with: " ")
    }

    /// WPM weight for a display token. Long joins get full per-word speak time; short joins stay compact.
    static func durationWeight(forDisplay display: String) -> Double {
        let parts = display.split { $0.isWhitespace }.map(String.init).filter { !$0.isEmpty }
        let wordUnits = max(1, parts.count)
        let letters = display.filter { !$0.isWhitespace }.count
        let charWeight = max(0.45, Double(letters) / 5.0)

        guard wordUnits > 1 else { return charWeight }

        // Short joins (2 brief words): mild multi-word bump.
        let isLongBundle = wordUnits >= 3 || letters >= 14
        if !isLongBundle {
            return max(Double(wordUnits) * 0.9, charWeight)
        }

        // Long joins: sum each component’s speak weight + a small breath between words.
        let perPart = parts.reduce(0.0) { partial, part in
            let len = part.filter { !$0.isWhitespace }.count
            return partial + max(0.85, Double(len) / 5.0)
        }
        let breaths = 0.22 * Double(wordUnits - 1)
        return perPart + breaths
    }

    private static func makePause(
        name: String,
        explicitSeconds: TimeInterval?,
        pacing: ScriptPacing
    ) -> SpokenWord {
        let wantsLong = name == "LONGPAUSE"
        let duration: TimeInterval
        let kind: ScriptPauseKind

        if let explicit = explicitSeconds {
            let clamped = min(60, max(0.05, explicit))
            duration = clamped
            if wantsLong || clamped >= ScriptPacing.longPauseThreshold {
                kind = .long
            } else {
                kind = .brief
            }
        } else if wantsLong {
            duration = pacing.longTagPause
            kind = .long
        } else {
            duration = pacing.tagPause
            kind = .brief
        }

        return SpokenWord(
            text: "",
            characterCount: 0,
            punctuationPause: duration,
            vocalStyle: .normal,
            baseDuration: 0,
            pauseKind: kind
        )
    }

    /// Splits on spaces while preserving hard line breaks from the script.
    private static func appendPlain(
        _ text: String,
        style: VocalStyle,
        secondsPerWord: TimeInterval,
        pacing: ScriptPacing,
        into words: inout [SpokenWord]
    ) {
        var current = ""
        var breaksOnFlush = 0

        func makeWord(_ token: String, breaks: Int) -> SpokenWord {
            let display = displayText(for: token)
            let pause = punctuationPause(for: display, pacing: pacing)
            return SpokenWord(
                text: display,
                punctuationPause: pause,
                vocalStyle: style,
                baseDuration: secondsPerWord * durationWeight(forDisplay: display),
                lineBreaksAfter: breaks,
                lineBreakHold: pacing.hold(forLineBreaks: breaks)
            )
        }

        func flush() {
            guard !current.isEmpty else { return }
            words.append(makeWord(current, breaks: breaksOnFlush))
            current = ""
            breaksOnFlush = 0
        }

        func rewrite(_ word: SpokenWord, breaks: Int) -> SpokenWord {
            SpokenWord(
                id: word.id,
                text: word.text,
                characterCount: word.characterCount,
                punctuationPause: word.punctuationPause,
                vocalStyle: word.vocalStyle,
                baseDuration: word.baseDuration,
                lineBreaksAfter: breaks,
                lineBreakHold: pacing.hold(forLineBreaks: breaks),
                pauseKind: word.pauseKind
            )
        }

        func addBreakToLastWord() {
            guard let last = words.popLast() else { return }
            if last.isPauseOnly {
                // Long-pause chips own their trailing newlines (hard wrap after the beat).
                // Brief invisible pauses push the break onto the prior speakable token.
                if last.isLongPause {
                    words.append(rewrite(last, breaks: last.lineBreaksAfter + 1))
                    return
                }
                if let prior = words.popLast() {
                    words.append(rewrite(prior, breaks: prior.lineBreaksAfter + 1))
                    words.append(last)
                } else {
                    words.append(rewrite(last, breaks: last.lineBreaksAfter + 1))
                }
                return
            }
            words.append(rewrite(last, breaks: last.lineBreaksAfter + 1))
        }

        for ch in text {
            if ch.isNewline {
                if !current.isEmpty {
                    breaksOnFlush += 1
                    flush()
                } else {
                    addBreakToLastWord()
                }
            } else if ch == joinGlue {
                current.append(ch)
            } else if ch == "_", !current.isEmpty, !Self.keepsUnderscore(current) {
                // `Build_on_Stellar` → one display phrase with spaces.
                current.append(joinGlue)
            } else if ch.isWhitespace {
                flush()
            } else {
                current.append(ch)
            }
        }
        flush()
    }

    /// Punctuation dwell for a token: hold **N** from pacing, gated by flourish **X** when motion is on.
    static func punctuationPause(
        for token: String,
        pacing: ScriptPacing = .default
    ) -> TimeInterval {
        pacing.punctuationDwell(for: token)
    }

    /// A website token keeps `_` (`https://stellar.org/a_b`). Phrase joins do not.
    private static func keepsUnderscore(_ current: String) -> Bool {
        current.contains("://") || current.contains("/") || current.contains(".")
    }
}

/// Website tokens in a spoken script: `https://…`, `http://…`, `www.…`, and bare paths such as `stellar.org/foundation`.
enum PromptWebsiteURL {
    static func match(_ raw: String, cues: [LinkCue] = []) -> String? {
        if let written = canonical(raw) { return written }
        let token = trim(raw).lowercased()
        guard token.count >= 4 else { return nil }
        var sameHost: [String] = []
        for cue in cues {
            let source = cue.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let copied = canonical(source) ?? canonical(cue.label) else { continue }
            let bare = stripScheme(copied).lowercased()
            let host = websiteHost(in: stripScheme(copied)).lowercased()
            if token == bare || token == copied.lowercased() || token == host {
                return copied
            }
            if !host.isEmpty, websiteHost(in: token).lowercased() == host {
                sameHost.append(copied)
            }
        }
        return sameHost.count == 1 ? sameHost[0] : nil
    }

    /// Copyable URL. A missing scheme becomes `https`. `http` stays `http`.
    static func canonical(_ raw: String) -> String? {
        let token = trim(raw)
        guard token.count >= 4 else { return nil }
        let scheme = explicitScheme(token)
        var body = token
        if let scheme {
            body = String(token.dropFirst(scheme.count + 3))
        } else if body.hasPrefix("//") {
            body = String(body.dropFirst(2))
        }
        guard !body.isEmpty, !body.contains(where: \.isWhitespace) else { return nil }
        let host = websiteHost(in: body)
        guard isWebsiteHost(host) else { return nil }
        if scheme == nil, let tld = host.split(separator: ".").last,
           fileExtensions.contains(String(tld).lowercased()) {
            return nil
        }
        return (scheme ?? "https") + "://" + body
    }

    /// Same document after WebKit normalizes the request: trailing slash, fragment, and default host case.
    static func samePage(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard let left = pageIdentity(lhs), let right = pageIdentity(rhs) else { return false }
        return left == right
    }

    private static func pageIdentity(_ raw: String) -> String? {
        guard let canonical = canonical(raw), var parts = URLComponents(string: canonical) else { return nil }
        parts.fragment = nil
        if parts.path.isEmpty {
            parts.path = "/"
        } else if parts.path.count > 1, parts.path.hasSuffix("/") {
            parts.path.removeLast()
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        return parts.string
    }

    private static func explicitScheme(_ token: String) -> String? {
        let lower = token.lowercased()
        if lower.hasPrefix("https://") { return "https" }
        if lower.hasPrefix("http://") { return "http" }
        return nil
    }

    private static func stripScheme(_ url: String) -> String {
        let lower = url.lowercased()
        if lower.hasPrefix("https://") { return String(url.dropFirst(8)) }
        if lower.hasPrefix("http://") { return String(url.dropFirst(7)) }
        if url.hasPrefix("//") { return String(url.dropFirst(2)) }
        return url
    }

    private static func websiteHost(in body: String) -> String {
        let authority = body.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? ""
        let afterUser = authority.split(separator: "@").last.map(String.init) ?? authority
        if afterUser.hasPrefix("["), let end = afterUser.firstIndex(of: "]") {
            return String(afterUser[...end])
        }
        if let colon = afterUser.lastIndex(of: ":"), afterUser[afterUser.index(after: colon)...].allSatisfy(\.isNumber) {
            return String(afterUser[..<colon])
        }
        return afterUser
    }

    private static func isWebsiteHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, (2...24).contains(tld.count), tld.allSatisfy(\.isLetter) else {
            return false
        }
        return labels.allSatisfy { label in
            guard (1...63).contains(label.count), let first = label.first, let last = label.last else { return false }
            guard first.isLetter || first.isNumber, last.isLetter || last.isNumber else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func trim(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,);]}!?\"'“”<>()[]…"))
    }

    private static let fileExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "webp", "svg", "mp3", "mp4", "mov", "wav",
        "txt", "json", "md", "zip", "csv", "doc", "docx", "ppt", "pptx", "xls", "xlsx",
        "css", "js", "ts", "html", "htm", "swift"
    ]
}

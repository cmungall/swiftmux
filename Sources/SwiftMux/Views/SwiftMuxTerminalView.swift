import AppKit
import Foundation
import SwiftTerm

final class SwiftMuxTerminalView: LocalProcessTerminalView {
    var currentWorkingDirectory: String?
    var sessionWorkingDirectory: String?
    var openErrorHandler: ((String) -> Void)?

    private var pendingOpenTarget: TerminalOpenTarget?
    private var pendingMouseDownLocation: CGPoint?
    private var preciseScrollAccumulator: CGFloat = 0
    private var lastPreciseScrollDirection = 0

    func beginCommandClick(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let target = openTarget(for: event) {
            pendingOpenTarget = target
            pendingMouseDownLocation = event.locationInWindow
            return true
        }

        pendingOpenTarget = nil
        pendingMouseDownLocation = nil
        return false
    }

    func completeCommandClick(with event: NSEvent) -> Bool {
        guard let target = pendingOpenTarget else {
            return false
        }

        defer {
            pendingOpenTarget = nil
            pendingMouseDownLocation = nil
        }

        guard event.modifierFlags.contains(.command), isClickRelease(event) else {
            return true
        }

        open(target)
        return true
    }

    func cancelPendingCommandClick() -> Bool {
        let hadPendingTarget = pendingOpenTarget != nil
        pendingOpenTarget = nil
        pendingMouseDownLocation = nil
        return hadPendingTarget
    }

    func handleScrollWheel(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        guard allowMouseReporting, terminal.mouseMode != .off else {
            resetPreciseScrollState()
            return false
        }

        let scrollSteps = scrollSteps(for: event, terminal: terminal)
        guard scrollSteps != 0 else {
            return event.hasPreciseScrollingDeltas || !event.momentumPhase.isEmpty
        }

        let hit = mouseHit(for: event, terminal: terminal)
        let modifiers = event.modifierFlags
        let button = scrollSteps > 0 ? 4 : 5

        for _ in 0..<abs(scrollSteps) {
            let buttonFlags = terminal.encodeButton(
                button: button,
                release: false,
                shift: modifiers.contains(.shift),
                meta: modifiers.contains(.option),
                control: modifiers.contains(.control)
            )

            terminal.sendEvent(
                buttonFlags: buttonFlags,
                x: hit.grid.col,
                y: hit.grid.row,
                pixelX: hit.pixel.col,
                pixelY: hit.pixel.row
            )
        }

        return true
    }

    func containsEventLocation(_ event: NSEvent) -> Bool {
        guard event.window === window else {
            return false
        }

        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    private func isClickRelease(_ event: NSEvent) -> Bool {
        guard let pendingMouseDownLocation else {
            return false
        }

        let dx = event.locationInWindow.x - pendingMouseDownLocation.x
        let dy = event.locationInWindow.y - pendingMouseDownLocation.y
        return hypot(dx, dy) <= 4
    }

    private func openTarget(for event: NSEvent) -> TerminalOpenTarget? {
        let hit = mouseHit(for: event, terminal: getTerminal()).grid
        return oscHyperlinkTarget(at: hit) ?? detectedTextTarget(at: hit)
    }

    private func oscHyperlinkTarget(at position: Position) -> TerminalOpenTarget? {
        guard let line = getTerminal().getLine(row: position.row),
              position.col >= 0,
              position.col < line.count,
              let payload = line[position.col].getPayload() as? String,
              let link = parseOSCHyperlinkPayload(payload) else {
            return nil
        }

        return target(forLink: link)
    }

    private func parseOSCHyperlinkPayload(_ payload: String) -> String? {
        let split = payload.split(separator: ";", maxSplits: Int.max, omittingEmptySubsequences: false)
        guard split.count > 1 else {
            return nil
        }
        return String(split[1])
    }

    private func detectedTextTarget(at position: Position) -> TerminalOpenTarget? {
        guard let snapshot = lineSnapshot(row: position.row),
              let offset = snapshot.utf16Offset(forColumn: position.col) else {
            return nil
        }

        if let urlTarget = detectedURLTarget(in: snapshot.text, at: offset) {
            return urlTarget
        }

        guard let token = token(in: snapshot.text, at: offset) else {
            return nil
        }
        return fileTarget(forToken: token)
    }

    private func detectedURLTarget(in text: String, at offset: Int) -> TerminalOpenTarget? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = Self.urlDetector?.matches(in: text, options: [], range: fullRange) ?? []

        for match in matches where match.range.contains(offset) {
            if let url = match.url {
                return .url(url)
            }
        }
        return nil
    }

    private func token(in text: String, at offset: Int) -> String? {
        let nsText = text as NSString
        guard offset >= 0, offset < nsText.length else {
            return nil
        }

        let clickedCharacter = Self.scalar(in: nsText, at: offset)
        guard !Self.tokenBoundaryCharacters.contains(clickedCharacter) else {
            return nil
        }

        var start = offset
        while start > 0 {
            let scalar = Self.scalar(in: nsText, at: start - 1)
            if Self.tokenBoundaryCharacters.contains(scalar) {
                break
            }
            start -= 1
        }

        var end = offset
        while end < nsText.length {
            let scalar = Self.scalar(in: nsText, at: end)
            if Self.tokenBoundaryCharacters.contains(scalar) {
                break
            }
            end += 1
        }

        var token = nsText.substring(with: NSRange(location: start, length: end - start))
        token.trimTerminalDelimiters()
        return token.isEmpty ? nil : token
    }

    private func fileTarget(forToken token: String) -> TerminalOpenTarget? {
        let parsed = parseFileToken(token)
        guard looksLikeFilePath(parsed.path),
              let url = resolvedFileURL(for: parsed.path) else {
            return nil
        }

        return .file(url: url, line: parsed.line, column: parsed.column)
    }

    private func parseFileToken(_ token: String) -> ParsedFileToken {
        let nsToken = token as NSString
        let fullRange = NSRange(location: 0, length: nsToken.length)

        if let match = Self.fileLineRegex.firstMatch(in: token, options: [], range: fullRange),
           match.numberOfRanges >= 3,
           let pathRange = Range(match.range(at: 1), in: token),
           let lineRange = Range(match.range(at: 2), in: token) {
            var path = String(token[pathRange])
            path.trimPathPunctuation()

            let line = Int(token[lineRange])
            var column: Int?
            if match.numberOfRanges >= 4,
               let columnRange = Range(match.range(at: 3), in: token) {
                column = Int(token[columnRange])
            }

            return ParsedFileToken(path: path, line: line, column: column)
        }

        var path = token
        path.trimPathPunctuation()
        return ParsedFileToken(path: path, line: nil, column: nil)
    }

    private func looksLikeFilePath(_ path: String) -> Bool {
        guard !path.isEmpty else {
            return false
        }

        return path.hasPrefix("/")
            || path.hasPrefix("~/")
            || path.hasPrefix("./")
            || path.hasPrefix("../")
            || path.contains("/")
            || !(path as NSString).pathExtension.isEmpty
    }

    private func resolvedFileURL(for path: String) -> URL? {
        if let url = URL(string: path), url.isFileURL {
            return existingFileURL(url.standardizedFileURL)
        }

        let expandedPath = (path as NSString).expandingTildeInPath
        let url: URL
        if expandedPath.hasPrefix("/") {
            url = URL(fileURLWithPath: expandedPath)
        } else if let directory = effectiveWorkingDirectory {
            url = URL(fileURLWithPath: expandedPath, relativeTo: URL(fileURLWithPath: directory))
        } else {
            return nil
        }

        return existingFileURL(url.standardizedFileURL)
    }

    private func existingFileURL(_ url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        return url
    }

    private var effectiveWorkingDirectory: String? {
        normalizeDirectory(currentWorkingDirectory) ?? normalizeDirectory(sessionWorkingDirectory)
    }

    private func normalizeDirectory(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }

        if let url = URL(string: value), url.isFileURL {
            return url.path
        }

        return (value as NSString).expandingTildeInPath
    }

    private func target(forLink link: String) -> TerminalOpenTarget? {
        if let url = URL(string: link), url.scheme != nil {
            if url.isFileURL {
                return .file(url: url.standardizedFileURL, line: nil, column: nil)
            }
            return .url(url)
        }

        return fileTarget(forToken: link)
    }

    private func open(_ target: TerminalOpenTarget) {
        switch target {
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .file(let url, let line, let column):
            openFile(url, line: line, column: column)
        }
    }

    private func openFile(_ url: URL, line: Int?, column: Int?) {
        if let editor = preferredEditorExecutable() {
            launch(editor, arguments: editorArguments(for: editor, url: url, line: line, column: column))
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func preferredEditorExecutable() -> String? {
        let environment = CommandRunner.baseEnvironment()
        var candidates: [String] = []

        if let configured = environment["SWIFTMUX_EDITOR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            candidates.append(configured)
        }

        candidates.append(contentsOf: ["cursor", "code", "windsurf", "zed", "xed"])

        for candidate in candidates {
            if candidate.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }

            if let resolved = resolveExecutable(named: candidate, path: environment["PATH"]) {
                return resolved
            }
        }

        return nil
    }

    private func resolveExecutable(named name: String, path: String?) -> String? {
        guard !name.contains("/") else {
            return nil
        }

        for directory in (path ?? "").split(separator: ":").map(String.init) {
            let executable = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: executable) {
                return executable
            }
        }

        return nil
    }

    private func editorArguments(for editor: String, url: URL, line: Int?, column: Int?) -> [String] {
        let editorName = URL(fileURLWithPath: editor).lastPathComponent
        let path = url.path

        switch editorName {
        case "code", "cursor", "windsurf":
            if let line {
                return ["-g", "\(path):\(line):\(column ?? 1)"]
            }
            return [path]
        case "zed":
            if let line {
                return ["\(path):\(line):\(column ?? 1)"]
            }
            return [path]
        case "xed":
            if let line {
                return ["-l", "\(line)", path]
            }
            return [path]
        default:
            return [path]
        }
    }

    private func launch(_ executable: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = CommandRunner.baseEnvironment()

        do {
            try process.run()
        } catch {
            openErrorHandler?("Failed to open \(arguments.last ?? "file"): \(error.localizedDescription)")
        }
    }

    private func lineSnapshot(row: Int) -> TerminalLineSnapshot? {
        let terminal = getTerminal()
        guard let line = terminal.getLine(row: row) else {
            return nil
        }

        var text = ""
        var ranges: [Range<Int>] = []
        var offset = 0
        let count = min(terminal.cols, line.count)

        for col in 0..<count {
            let character = line[col].getCharacter()
            let string = character.isNullCharacter ? " " : String(character)
            let length = string.utf16.count
            ranges.append(offset..<(offset + length))
            text.append(contentsOf: string)
            offset += length
        }

        return TerminalLineSnapshot(text: text, cellUTF16Ranges: ranges)
    }

    private func scrollSteps(for event: NSEvent, terminal: Terminal) -> Int {
        if !event.momentumPhase.isEmpty {
            resetPreciseScrollState()
            return 0
        }

        let preciseDeltaY = event.scrollingDeltaY == 0 ? event.deltaY : event.scrollingDeltaY
        let deltaY = event.hasPreciseScrollingDeltas ? preciseDeltaY : event.deltaY
        guard deltaY != 0 else {
            if !event.phase.isEmpty {
                resetPreciseScrollState()
            }
            return 0
        }

        if !event.hasPreciseScrollingDeltas {
            resetPreciseScrollState()
            let steps = max(Int(abs(deltaY).rounded(.awayFromZero)), 1)
            return deltaY > 0 ? steps : -steps
        }

        let direction = deltaY > 0 ? 1 : -1
        if direction != lastPreciseScrollDirection {
            preciseScrollAccumulator = 0
            lastPreciseScrollDirection = direction
        }

        let rows = max(terminal.rows, 1)
        let lineHeight = max(bounds.height / CGFloat(rows), 1)
        preciseScrollAccumulator += deltaY

        let steps = Int(abs(preciseScrollAccumulator) / lineHeight)
        if steps > 0 {
            preciseScrollAccumulator -= CGFloat(direction * steps) * lineHeight
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            resetPreciseScrollState()
        }

        return direction * steps
    }

    private func resetPreciseScrollState() {
        preciseScrollAccumulator = 0
        lastPreciseScrollDirection = 0
    }

    private func mouseHit(for event: NSEvent, terminal: Terminal) -> (grid: Position, pixel: Position) {
        let point = convert(event.locationInWindow, from: nil)
        let clampedX = min(max(point.x, 0), bounds.width)
        let clampedY = min(max(point.y, 0), bounds.height)
        let cols = max(terminal.cols, 1)
        let rows = max(terminal.rows, 1)
        let cellWidth = max(bounds.width / CGFloat(cols), 1)
        let cellHeight = max(bounds.height / CGFloat(rows), 1)

        let gridCol = min(max(Int(clampedX / cellWidth), 0), cols - 1)
        let gridRow = min(max(Int((bounds.height - clampedY) / cellHeight), 0), rows - 1)
        let pixelCol = Int(clampedX)
        let pixelRow = Int(bounds.height - clampedY)

        return (
            grid: Position(col: gridCol, row: gridRow),
            pixel: Position(col: pixelCol, row: pixelRow)
        )
    }

    private static let urlDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    private static let fileLineRegex = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+)(?::(\d+))?:?$"#,
        options: []
    )
    private static let tokenBoundaryCharacters = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)

    private static func scalar(in text: NSString, at offset: Int) -> UnicodeScalar {
        UnicodeScalar(UInt32(text.character(at: offset))) ?? UnicodeScalar(0)!
    }
}

private enum TerminalOpenTarget {
    case url(URL)
    case file(url: URL, line: Int?, column: Int?)
}

private struct ParsedFileToken {
    let path: String
    let line: Int?
    let column: Int?
}

private struct TerminalLineSnapshot {
    let text: String
    let cellUTF16Ranges: [Range<Int>]

    func utf16Offset(forColumn column: Int) -> Int? {
        guard column >= 0, column < cellUTF16Ranges.count else {
            return nil
        }
        return cellUTF16Ranges[column].lowerBound
    }
}

private extension Character {
    var isNullCharacter: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first?.value == 0
    }
}

private extension String {
    mutating func trimTerminalDelimiters() {
        let leadingDelimiters: Set<Character> = ["\"", "'", "`", "(", "[", "{", "<"]
        let trailingDelimiters: Set<Character> = ["\"", "'", "`", ")", "]", "}", ">", ",", ";", "."]

        while let first, leadingDelimiters.contains(first) {
            removeFirst()
        }

        while let last, trailingDelimiters.contains(last) {
            removeLast()
        }
    }

    mutating func trimPathPunctuation() {
        let trailingPunctuation: Set<Character> = [",", ";", ".", ":"]

        while let last, trailingPunctuation.contains(last) {
            removeLast()
        }
    }
}

private extension NSRange {
    func contains(_ offset: Int) -> Bool {
        offset >= location && offset < location + length
    }
}

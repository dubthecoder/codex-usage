import AppKit
import Combine
import Foundation
import SwiftUI

struct TokenUsage: Equatable {
    var input: Int = 0
    var cachedInput: Int = 0
    var nonCachedInput: Int = 0
    var output: Int = 0
    var reasoningOutput: Int = 0
    var total: Int = 0

    mutating func add(_ other: TokenUsage) {
        input += other.input
        cachedInput += other.cachedInput
        nonCachedInput += other.nonCachedInput
        output += other.output
        reasoningOutput += other.reasoningOutput
        total += other.total
    }
}

struct CodexTurn: Identifiable {
    let id = UUID()
    let date: Date
    let threadID: String
    let model: String
    let effort: String
    let usage: TokenUsage
}

struct CodexRateLimit {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
}

struct CodexStatus {
    let date: Date
    let totalUsage: TokenUsage
    let lastUsage: TokenUsage
    let modelContextWindow: Int?
    let primary: CodexRateLimit?
    let secondary: CodexRateLimit?
    let planType: String?
    let sourcePath: String
}

struct UsageSnapshot {
    var generatedAt = Date()
    var turnsToday = 0
    var turnsLast24Hours = 0
    var turnsLast7Days = 0
    var today = TokenUsage()
    var last24Hours = TokenUsage()
    var last7Days = TokenUsage()
    var latestTurn: CodexTurn?
    var byModel: [(String, TokenUsage)] = []
    var byEffort: [(String, TokenUsage)] = []
    var codexStatus: CodexStatus?
    var logPath: String = CodexUsageReader.defaultLogPath
    var error: String?

    static let empty = UsageSnapshot()
}

final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty

    private let reader = CodexUsageReader()
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        snapshot = reader.read()
    }
}

final class CodexUsageReader {
    static let defaultLogPath = NSString(string: "~/.codex/log/codex-tui.log").expandingTildeInPath
    static let defaultSessionsPath = NSString(string: "~/.codex/sessions").expandingTildeInPath

    private let logPath: String
    private let sessionsPath: String
    private let maxBytes: UInt64 = 20 * 1024 * 1024
    private let isoFormatter: ISO8601DateFormatter
    private let tokenRegex: NSRegularExpression
    private let decoder: JSONDecoder

    init(
        logPath: String = CodexUsageReader.defaultLogPath,
        sessionsPath: String = CodexUsageReader.defaultSessionsPath
    ) {
        self.logPath = logPath
        self.sessionsPath = sessionsPath
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        tokenRegex = try! NSRegularExpression(pattern: #"codex\.turn\.token_usage\.([a-z_]+)=([0-9]+)"#)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func read(now: Date = Date()) -> UsageSnapshot {
        var snapshot = UsageSnapshot(generatedAt: now, logPath: logPath)

        do {
            let turns: [CodexTurn]
            if FileManager.default.fileExists(atPath: logPath) {
                let text = try readTail(at: URL(fileURLWithPath: logPath), maxBytes: maxBytes)
                turns = parseTurns(from: text)
            } else {
                turns = []
            }

            snapshot = summarize(turns: turns, now: now)
            snapshot.logPath = logPath
            snapshot.codexStatus = try readLatestStatus()

            if snapshot.codexStatus == nil && turns.isEmpty {
                snapshot.error = "No Codex usage data found"
            }

            return snapshot
        } catch {
            snapshot.error = error.localizedDescription
            return snapshot
        }
    }

    private func readTail(at url: URL, maxBytes: UInt64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let offset = size > maxBytes ? size - maxBytes : 0
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        var text = String(decoding: data, as: UTF8.self)

        if offset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...firstNewline)
        }

        return text
    }

    private func readLatestStatus() throws -> CodexStatus? {
        let root = URL(fileURLWithPath: sessionsPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }

        let files = recentJSONLFiles(under: root).prefix(60)

        for file in files {
            let text = try readTail(at: file, maxBytes: 8 * 1024 * 1024)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).reversed()

            for line in lines {
                guard line.contains(#""type":"token_count""#) else { continue }
                if let status = parseStatusLine(String(line), sourcePath: file.path) {
                    return status
                }
            }
        }

        return nil
    }

    private func recentJSONLFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modified: Date)] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }

        return files
            .sorted { $0.modified > $1.modified }
            .map(\.url)
    }

    private func parseStatusLine(_ line: String, sourcePath: String) -> CodexStatus? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let event = try? decoder.decode(StatusEvent.self, from: data) else { return nil }
        guard event.type == "event_msg", event.payload.type == "token_count" else { return nil }
        guard let date = isoFormatter.date(from: event.timestamp) else { return nil }

        return CodexStatus(
            date: date,
            totalUsage: event.payload.info.totalTokenUsage.asTokenUsage,
            lastUsage: event.payload.info.lastTokenUsage.asTokenUsage,
            modelContextWindow: event.payload.info.modelContextWindow,
            primary: event.payload.rateLimits?.primary?.asCodexRateLimit,
            secondary: event.payload.rateLimits?.secondary?.asCodexRateLimit,
            planType: event.payload.rateLimits?.planType,
            sourcePath: sourcePath
        )
    }

    private func parseTurns(from text: String) -> [CodexTurn] {
        text.split(separator: "\n").compactMap { parseTurn(line: String($0)) }
    }

    private func parseTurn(line: String) -> CodexTurn? {
        guard line.contains("codex.turn.token_usage.total_tokens=") else { return nil }
        guard let date = parseDate(from: line) else { return nil }

        let usage = parseUsage(from: line)
        guard usage.total > 0 else { return nil }

        return CodexTurn(
            date: date,
            threadID: fieldValue("thread.id", in: line) ?? "unknown",
            model: fieldValue("model", in: line) ?? "unknown",
            effort: fieldValue("codex.turn.reasoning_effort", in: line) ?? "unknown",
            usage: usage
        )
    }

    private func parseDate(from line: String) -> Date? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        return isoFormatter.date(from: String(line[..<space]))
    }

    private func parseUsage(from line: String) -> TokenUsage {
        let nsLine = line as NSString
        let matches = tokenRegex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        var fields: [String: Int] = [:]

        for match in matches {
            guard match.numberOfRanges == 3 else { continue }
            let key = nsLine.substring(with: match.range(at: 1))
            let value = Int(nsLine.substring(with: match.range(at: 2))) ?? 0
            fields[key] = value
        }

        return TokenUsage(
            input: fields["input_tokens"] ?? 0,
            cachedInput: fields["cached_input_tokens"] ?? 0,
            nonCachedInput: fields["non_cached_input_tokens"] ?? 0,
            output: fields["output_tokens"] ?? 0,
            reasoningOutput: fields["reasoning_output_tokens"] ?? 0,
            total: fields["total_tokens"] ?? 0
        )
    }

    private func fieldValue(_ field: String, in line: String) -> String? {
        guard let range = line.range(of: "\(field)=") else { return nil }
        let valueStart = range.upperBound
        let valueEnd = line[valueStart...].firstIndex { $0 == " " || $0 == "}" } ?? line.endIndex
        let raw = String(line[valueStart..<valueEnd])
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func summarize(turns: [CodexTurn], now: Date) -> UsageSnapshot {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let last24Start = now.addingTimeInterval(-24 * 60 * 60)
        let last7Start = now.addingTimeInterval(-7 * 24 * 60 * 60)

        let todayTurns = turns.filter { $0.date >= startOfToday && $0.date <= now }
        let last24Turns = turns.filter { $0.date >= last24Start && $0.date <= now }
        let last7Turns = turns.filter { $0.date >= last7Start && $0.date <= now }

        var snapshot = UsageSnapshot(generatedAt: now)
        snapshot.turnsToday = todayTurns.count
        snapshot.turnsLast24Hours = last24Turns.count
        snapshot.turnsLast7Days = last7Turns.count
        snapshot.today = todayTurns.reduce(TokenUsage()) { partial, turn in
            var usage = partial
            usage.add(turn.usage)
            return usage
        }
        snapshot.last24Hours = last24Turns.reduce(TokenUsage()) { partial, turn in
            var usage = partial
            usage.add(turn.usage)
            return usage
        }
        snapshot.last7Days = last7Turns.reduce(TokenUsage()) { partial, turn in
            var usage = partial
            usage.add(turn.usage)
            return usage
        }
        snapshot.latestTurn = turns.max(by: { $0.date < $1.date })
        snapshot.byModel = aggregate(last24Turns, key: \.model)
        snapshot.byEffort = aggregate(last24Turns, key: \.effort)
        return snapshot
    }

    private func aggregate(_ turns: [CodexTurn], key: KeyPath<CodexTurn, String>) -> [(String, TokenUsage)] {
        var buckets: [String: TokenUsage] = [:]

        for turn in turns {
            var usage = buckets[turn[keyPath: key], default: TokenUsage()]
            usage.add(turn.usage)
            buckets[turn[keyPath: key]] = usage
        }

        return buckets
            .map { ($0.key, $0.value) }
            .sorted { $0.1.total > $1.1.total }
    }
}

private struct StatusEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: StatusPayload
}

private struct StatusPayload: Decodable {
    let type: String
    let info: StatusInfo
    let rateLimits: StatusRateLimits?
}

private struct StatusInfo: Decodable {
    let totalTokenUsage: StatusTokenUsage
    let lastTokenUsage: StatusTokenUsage
    let modelContextWindow: Int?
}

private struct StatusTokenUsage: Decodable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int

    var asTokenUsage: TokenUsage {
        TokenUsage(
            input: inputTokens,
            cachedInput: cachedInputTokens,
            nonCachedInput: max(0, inputTokens - cachedInputTokens),
            output: outputTokens,
            reasoningOutput: reasoningOutputTokens,
            total: totalTokens
        )
    }
}

private struct StatusRateLimits: Decodable {
    let primary: StatusRateLimit?
    let secondary: StatusRateLimit?
    let planType: String?
    let rateLimitReachedType: String?
}

private struct StatusRateLimit: Decodable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Double

    var asCodexRateLimit: CodexRateLimit {
        CodexRateLimit(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }
}

struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    var onQuit: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            header

            Divider()
                .opacity(0.6)

            if let error = store.snapshot.error {
                Text(error)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 170)
            } else if let status = store.snapshot.codexStatus {
                UsageMeter(
                    percent: (status.primary?.usedPercent ?? 0) / 100,
                    label: "Current",
                    resetText: resetText(for: status.primary, now: store.snapshot.generatedAt),
                    detailText: windowLabel(status.primary)
                )

                UsageMeter(
                    percent: (status.secondary?.usedPercent ?? 0) / 100,
                    label: "Weekly",
                    resetText: resetText(for: status.secondary, now: store.snapshot.generatedAt),
                    detailText: windowLabel(status.secondary)
                )

                compactStats(status)
            } else {
                Text("Open Codex /status once to populate usage")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 170)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(width: 360)
        .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("Codex Usage")
                    .font(.headline)
                Text("Updated \(store.snapshot.generatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .help("Refresh usage")
            .accessibilityLabel("Refresh usage")

            if let onQuit {
                Button {
                    onQuit()
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .help("Quit Codex Usage Watcher")
                .accessibilityLabel("Quit Codex Usage Watcher")
            }
        }
    }

    private func compactStats(_ status: CodexStatus) -> some View {
        VStack(spacing: 6) {
            statRow("Plan", value: (status.planType ?? "unknown").capitalized)
            Divider().opacity(0.4)
            statRow("Last turn", value: "\(formatTokens(status.lastUsage.total)) tokens")
            Divider().opacity(0.4)
            statRow("Session", value: "\(formatTokens(status.totalUsage.total)) tokens")
            Divider().opacity(0.4)
            statRow("Context window", value: formatTokens(status.modelContextWindow ?? 0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }

    private func statRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private func resetText(for limit: CodexRateLimit?, now: Date) -> String {
        guard let limit else { return "Reset unavailable" }
        if limit.resetsAt <= now {
            return "Reset window elapsed"
        }
        return "Resets in \(compactDuration(from: now, to: limit.resetsAt))"
    }

    private func windowLabel(_ limit: CodexRateLimit?) -> String {
        guard let minutes = limit?.windowMinutes else { return "Codex quota" }
        if minutes % 10_080 == 0 {
            return "\(minutes / 10_080 * 7)d window"
        }
        if minutes % 1_440 == 0 {
            return "\(minutes / 1_440)d window"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h window"
        }
        return "\(minutes)m window"
    }
}

struct UsageMeter: View {
    let percent: Double
    let label: String
    let resetText: String
    let detailText: String

    private var clampedPercent: Double { min(max(percent, 0), 1) }

    private var accent: Color {
        switch clampedPercent {
        case ..<0.6: return Color(nsColor: .systemGreen)
        case ..<0.85: return Color(nsColor: .systemYellow)
        default: return Color(nsColor: .systemRed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Spacer()

                Text("\(Int((clampedPercent * 100).rounded()))%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .quaternaryLabelColor))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(4, proxy.size.width * clampedPercent))
                }
            }
            .frame(height: 6)

            HStack {
                Text(resetText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(detailText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

func formatTokens(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.1fk", Double(value) / 1_000)
    }
    return "\(value)"
}

func timeUntilEndOfDay(from date: Date) -> String {
    let calendar = Calendar.current
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
    return compactDuration(from: date, to: tomorrow)
}

func timeUntilNextWeek(from date: Date) -> String {
    let calendar = Calendar.current
    let nextWeek = calendar.nextDate(
        after: date,
        matching: DateComponents(hour: 0, minute: 0, second: 0, weekday: calendar.firstWeekday),
        matchingPolicy: .nextTime
    ) ?? date.addingTimeInterval(7 * 24 * 60 * 60)
    return compactDuration(from: date, to: nextWeek)
}

func compactDuration(from start: Date, to end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60

    if days > 0 {
        return "\(days)d \(hours)h"
    }
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    if minutes > 0 {
        return "\(minutes)m"
    }
    if seconds > 0 {
        return "<1m"
    }
    return "now"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store = UsageStore()
    private var statusCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        configureStatusItem()
        configurePopover()

        statusCancellable = store.$snapshot.sink { [weak self] snapshot in
            self?.updateStatusTitle(snapshot)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePopover)
        button.target = self
        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.50percent",
            accessibilityDescription: "Codex Usage"
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 420)
        let controller = NSHostingController(rootView: UsagePanel(store: store) { [weak self] in
            self?.quitFromPanel()
        })
        popover.contentViewController = controller
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusTitle(_ snapshot: UsageSnapshot) {
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }

            let title: String
            if snapshot.error != nil {
                title = "—"
            } else if let percent = snapshot.codexStatus?.primary?.usedPercent {
                title = " \(Int(percent.rounded()))%"
            } else {
                title = " —"
            }

            let font = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .medium)
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: font]
            )
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func quitFromPanel() {
        NSApp.terminate(nil)
    }

}

if CommandLine.arguments.contains("--snapshot") {
    let snapshot = CodexUsageReader().read()

    if let error = snapshot.error {
        print("error=\(error)")
        exit(1)
    }

    print("today_total_tokens=\(snapshot.today.total)")
    print("today_turns=\(snapshot.turnsToday)")
    print("last_24h_total_tokens=\(snapshot.last24Hours.total)")
    print("last_24h_turns=\(snapshot.turnsLast24Hours)")

    if let status = snapshot.codexStatus {
        print("status_primary_used_percent=\(status.primary?.usedPercent ?? 0)")
        print("status_primary_resets_at=\(Int(status.primary?.resetsAt.timeIntervalSince1970 ?? 0))")
        print("status_secondary_used_percent=\(status.secondary?.usedPercent ?? 0)")
        print("status_secondary_resets_at=\(Int(status.secondary?.resetsAt.timeIntervalSince1970 ?? 0))")
        print("status_plan_type=\(status.planType ?? "unknown")")
        print("status_last_total_tokens=\(status.lastUsage.total)")
        print("status_session_total_tokens=\(status.totalUsage.total)")
    }

    if let latestTurn = snapshot.latestTurn {
        print("latest_model=\(latestTurn.model)")
        print("latest_effort=\(latestTurn.effort)")
        print("latest_total_tokens=\(latestTurn.usage.total)")
    }

    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

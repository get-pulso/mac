import AppKit
import Combine
import CoreServices
import Defaults
import Foundation
import Logging

/// Watches the Claude Code, Codex, Cursor and opencode logs on this Mac,
/// folds them into daily token aggregates and per-minute agent activity, and
/// uploads both.
/// Runs only for accounts that opted in through Settings › Developer. Prompts,
/// transcripts, working directories and file names never leave the parsers.
@MainActor
final class AgentUsageCollector: ObservableObject {
    // MARK: Lifecycle

    nonisolated init(storage: Storage, network: Network, tracker: Tracker) {
        self.storage = storage
        self.network = network
        self.tracker = tracker
        self.roots = AgentUsageRoots()
        self.scanner = AgentUsageScanner(storage: storage, tracker: tracker, roots: self.roots)
    }

    // MARK: Internal

    struct ToolStatus: Identifiable {
        let tool: AgentTool
        let detected: Bool
        /// Human readable, e.g. "~/.claude".
        let location: String

        var id: AgentTool { self.tool }
    }

    struct Status {
        var enabled = false
        var lastScanAt: Date?
        var lastUploadAt: Date?
        var pendingRows = 0
        var backfilling = false
        var lastError: String?
        var todayTokens: Int64 = 0
        var todayAgentMinutes = 0
    }

    /// How far back a rebuild reads. A year, because a streak or a record is
    /// only worth the history under it; the tools decide how much of that
    /// year still exists (Claude Code clears its own logs after thirty days,
    /// Codex keeps its archive). Read once per counting version, not per scan.
    nonisolated static let backfillDays = 365

    /// How far back the scans between rebuilds look. A log that has not been
    /// written to in a month was read by the rebuild and has nothing new.
    nonisolated static let scanWindowDays = 30

    /// Raise this whenever the parsers or the counting rules change, so every
    /// Mac rebuilds its window once and the stored history is corrected.
    /// 2: Codex archived sessions are read, and a message copied into a
    /// resumed session's transcript is counted once rather than per file.
    /// 3: opencode's message store is read.
    /// 4: the window is a year, not thirty days, so every Mac sends the
    /// history it still has once.
    nonisolated static let countingVersion = 4

    @Published private(set) var status = Status()

    /// On unless the account turned it off. Reading how long the coding
    /// agents worked is part of what the app records, like the foreground
    /// app, so it needs no switch of its own.
    func isEnabled(for userID: String) -> Bool {
        Defaults[.agentTrackingAccounts][userID] ?? true
    }

    /// Persists the per-account choice and starts or stops watching when the
    /// account is the signed-in one.
    func setEnabled(_ enabled: Bool, for userID: String) {
        var accounts = Defaults[.agentTrackingAccounts]
        accounts[userID] = enabled
        Defaults[.agentTrackingAccounts] = accounts
        self.reconcile()
    }

    func toolStatuses() -> [ToolStatus] {
        AgentTool.allCases.map { tool in
            ToolStatus(tool: tool, detected: self.roots.isDetected(tool), location: self.roots.displayLocation(tool))
        }
    }

    func activate() {
        guard self.subscriptions.isEmpty else { return }
        Defaults.publisher(.currentUserID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &self.subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleIncrementalScan() }
            .store(in: &self.subscriptions)
        self.reconcile()
    }

    /// Rescans every log in the window from scratch. Day rows inside the window
    /// are rebuilt and re-uploaded; the server replaces them per row.
    /// Answers whether the rebuild ran to the end for the account it began
    /// with. A file that would not parse does not make it unfinished: the
    /// ordinary scans come back to it, and a rebuild that repeated on every
    /// launch over one bad log would read a year of them each time.
    @discardableResult
    func backfill(days: Int = AgentUsageCollector.backfillDays) async -> Bool {
        guard let userID = self.activeUserID, !self.status.backfilling else { return false }
        self.status.backfilling = true
        self.status.lastError = nil
        defer { self.status.backfilling = false }
        let since = self.windowStart(days: days, for: userID)
        let outcome = await self.scanner.rebuild(userID: userID, since: since)
        guard self.activeUserID == userID else { return false }
        self.finish(outcome)
        self.uploadIfNeeded()
        return true
    }

    /// Called by the activity reset: waits for in-flight uploads, deletes every
    /// local agent row for the account and moves the cut-off to now, so the
    /// history the server just cleared is never re-sent from this Mac.
    func drainAndClear(for userID: String) async throws {
        let wasActive = self.activeUserID == userID
        self.stop()
        self.uploadTask?.cancel()
        await self.uploadTask?.value
        await self.scanner.settle()
        try self.storage.deleteAgentUsage(for: userID)
        var floors = Defaults[.agentUsageFloor]
        floors[userID] = Date.now.timeIntervalSince1970
        Defaults[.agentUsageFloor] = floors
        self.status.todayTokens = 0
        self.status.todayAgentMinutes = 0
        self.status.pendingRows = 0
        self.uploadedMinutesToday = []
        if wasActive { self.reconcile() }
    }

    // MARK: Private

    private struct Ack: Decodable { let success: Bool? }

    private let logger = Logger(label: "firstlight.agent-usage")
    private nonisolated(unsafe) let storage: Storage
    private let network: Network
    private nonisolated(unsafe) let tracker: Tracker
    private let roots: AgentUsageRoots
    private let scanner: AgentUsageScanner
    private var subscriptions = Set<AnyCancellable>()
    private var activeUserID: String?
    private var watcher: AgentLogWatcher?
    private var loopTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var cursorTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var pendingPaths: [String: AgentTool] = [:]
    private var uploadedMinutesToday: Set<String> = []
    private var uploadedMinutesDate = ""

    private var deviceID: String {
        if let id = Defaults[.agentDeviceID] { return id }
        let id = UUID().uuidString
        Defaults[.agentDeviceID] = id
        return id
    }

    private func reconcile() {
        guard let userID = Defaults[.currentUserID], self.isEnabled(for: userID) else {
            self.stop()
            return
        }
        self.start(for: userID)
    }

    private func start(for userID: String) {
        guard self.activeUserID != userID else { return }
        self.stop()
        self.activeUserID = userID
        self.status = Status(enabled: true)
        self.logger.info("Agent usage collection started")

        let watcher = AgentLogWatcher(paths: self.roots.watchedDirectories) { [weak self] paths in
            Task { @MainActor in self?.handle(changedPaths: paths) }
        }
        watcher.start()
        self.watcher = watcher

        self.loopTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                tick += 1
                self.uploadIfNeeded()
                if tick % 5 == 0 { self.scheduleIncrementalScan() }
            }
        }

        let firstRun = ((try? self.storage.agentParseStates(for: userID)) ?? []).isEmpty
        let countedBy = Defaults[.agentCollectorVersion][userID] ?? 0
        if firstRun || countedBy < Self.countingVersion {
            // The version is written once the rebuild has read everything,
            // not before it starts. A year of logs takes minutes, and an app
            // quit in the middle of them used to be recorded as done: the
            // next launch scanned only the last month and the older history
            // was never read again.
            Task {
                guard await self.backfill() else { return }
                var versions = Defaults[.agentCollectorVersion]
                versions[userID] = Self.countingVersion
                Defaults[.agentCollectorVersion] = versions
            }
        } else {
            self.scheduleIncrementalScan()
            self.scheduleCursorRead(delay: .seconds(5))
        }
        self.refreshStatus()
    }

    private func stop() {
        self.watcher?.stop()
        self.watcher = nil
        self.loopTask?.cancel()
        self.loopTask = nil
        self.scanTask?.cancel()
        self.scanTask = nil
        self.cursorTask?.cancel()
        self.cursorTask = nil
        self.pendingPaths = [:]
        self.activeUserID = nil
        self.status.enabled = false
        self.status.backfilling = false
    }

    private func windowStart(days: Int, for userID: String) -> Date {
        let window = Date.now.addingTimeInterval(-Double(days) * 86400)
        guard let floor = Defaults[.agentUsageFloor][userID] else { return window }
        return max(window, Date(timeIntervalSince1970: floor))
    }

    private func handle(changedPaths paths: [String]) {
        guard self.activeUserID != nil else { return }
        var touchedCursor = false
        for path in paths {
            if let tool = self.roots.transcriptTool(for: path) {
                self.pendingPaths[path] = tool
            } else if self.roots.isCursorDatabase(path) {
                touchedCursor = true
            }
        }
        if !self.pendingPaths.isEmpty { self.scheduleFileScan() }
        if touchedCursor { self.scheduleCursorRead(delay: .seconds(60)) }
    }

    /// Parses the appended bytes of the files FSEvents reported. Coalesced so a
    /// burst of writes to one transcript is read once.
    private func scheduleFileScan() {
        guard self.scanTask == nil, let userID = self.activeUserID else { return }
        self.scanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            let files = self.pendingPaths
            self.pendingPaths = [:]
            self.scanTask = nil
            guard !files.isEmpty else { return }
            let since = self.windowStart(days: Self.scanWindowDays, for: userID)
            let outcome = await self.scanner.scan(files: files, userID: userID, since: since)
            guard self.activeUserID == userID else { return }
            self.finish(outcome)
            if !self.pendingPaths.isEmpty { self.scheduleFileScan() }
        }
    }

    /// Safety net: walks the roots for files changed inside the window.
    private func scheduleIncrementalScan() {
        guard let userID = self.activeUserID, !self.status.backfilling else { return }
        Task { [weak self] in
            guard let self else { return }
            let since = self.windowStart(days: Self.scanWindowDays, for: userID)
            let outcome = await self.scanner.scanAll(userID: userID, since: since)
            guard self.activeUserID == userID else { return }
            self.finish(outcome)
        }
        self.scheduleCursorRead(delay: .seconds(1), onlyIfChanged: true)
    }

    private func scheduleCursorRead(delay: Duration, onlyIfChanged: Bool = false) {
        guard let userID = self.activeUserID else { return }
        self.cursorTask?.cancel()
        self.cursorTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.cursorTask = nil
            let since = self.windowStart(days: Self.scanWindowDays, for: userID)
            let outcome = await self.scanner.readCursor(userID: userID, since: since, onlyIfChanged: onlyIfChanged)
            guard self.activeUserID == userID else { return }
            self.finish(outcome)
        }
    }

    private func finish(_ outcome: AgentUsageScanner.Outcome) {
        if let error = outcome.error {
            self.status.lastError = error
            self.logger.warning("Agent usage scan problem: \(error)")
        }
        if outcome.scanned { self.status.lastScanAt = .now }
        self.refreshStatus()
        if outcome.changed { self.uploadIfNeeded() }
    }

    private func refreshStatus() {
        guard let userID = self.activeUserID else { return }
        let today = AgentUsageDates.localDate(.now, calendar: .current)
        if self.uploadedMinutesDate != today {
            self.uploadedMinutesDate = today
            self.uploadedMinutesToday = []
        }
        let days = (try? self.storage.agentUsageDays(for: userID)) ?? []
        let pending = (try? self.storage.pendingAgentActivity(for: userID)) ?? []
        self.status.pendingRows = days.filter(\.dirty).count + pending.count
        self.status.todayTokens = days.filter { $0.key.date == today }.reduce(0) { $0 + $1.day.totalTokens }
        let pendingToday = pending.filter { AgentUsageDates.localDate($0.startedAt, calendar: .current) == today }
        self.status.todayAgentMinutes = Set(pendingToday.map(\.minuteID)).union(self.uploadedMinutesToday).count
    }

    private func uploadIfNeeded() {
        guard let userID = self.activeUserID, self.uploadTask == nil else { return }
        self.uploadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.uploadTask = nil }
            do {
                try await self.upload(for: userID)
                guard self.activeUserID == userID else { return }
                self.status.lastError = nil
            } catch is CancellationError {
                return
            } catch {
                guard self.activeUserID == userID else { return }
                self.status.lastError = error.localizedDescription
                self.logger.warning("Agent usage upload deferred; queued data is retained.")
            }
            self.refreshStatus()
        }
    }

    private func upload(for userID: String) async throws {
        let dirty = try self.storage.dirtyAgentUsageDays(for: userID)
        var uploaded = false
        for chunk in dirty.chunks(of: 400) {
            let body = DailyPayload(device_id: self.deviceID, rows: chunk.map(DailyRow.init(record:)))
            let ack: Ack = try await self.network.request(
                path: "/api/user/agent-usage/daily",
                method: .put,
                body: body,
                expectedUserID: userID
            )
            guard ack.success != false else { throw NativeError.message("The server rejected the usage rows.") }
            try self.storage.markAgentUsageUploaded(chunk)
            uploaded = true
        }

        let pending = try self.storage.pendingAgentActivity(for: userID)
        let today = AgentUsageDates.localDate(.now, calendar: .current)
        for chunk in pending.chunks(of: 500) {
            let body = ActivityPayload(intervals: chunk.map(ActivityInterval.init(minute:)))
            let ack: Ack = try await self.network.request(
                path: "/api/user/agent-activity",
                method: .post,
                body: body,
                expectedUserID: userID
            )
            guard ack.success != false else { throw NativeError.message("The server rejected the agent minutes.") }
            try self.storage.deletePendingAgentActivity(ids: chunk.map(\.id))
            for minute in chunk where AgentUsageDates.localDate(minute.startedAt, calendar: .current) == today {
                self.uploadedMinutesToday.insert(minute.minuteID)
            }
            uploaded = true
        }
        if uploaded { self.status.lastUploadAt = .now }
    }
}

// MARK: - Upload payloads

private struct DailyPayload: Encodable {
    let device_id: String
    let rows: [DailyRow]
}

private struct DailyRow: Encodable {
    // MARK: Lifecycle

    init(record: AgentUsageDayRecord) {
        self.date = record.key.date
        self.tool = record.key.tool.rawValue
        self.model = record.key.model
        self.input_tokens = record.day.input
        self.cache_write_tokens = record.day.cacheWrite
        self.cache_read_tokens = record.day.cacheRead
        self.output_tokens = record.day.output
        self.reasoning_tokens = record.day.reasoning
        self.requests = record.day.requests
        self.sessions = record.day.sessions
        self.reported_cost_cents = record.day.reportedCostCents
    }

    // MARK: Internal

    enum CodingKeys: String, CodingKey {
        case date, tool, model, input_tokens, cache_write_tokens, cache_read_tokens, output_tokens, reasoning_tokens,
             requests, sessions, reported_cost_cents
    }

    let date: String
    let tool: String
    let model: String
    let input_tokens: Int64
    let cache_write_tokens: Int64
    let cache_read_tokens: Int64
    let output_tokens: Int64
    let reasoning_tokens: Int64
    let requests: Int
    let sessions: Int
    let reported_cost_cents: Int?

    /// Explicit so a missing Cursor cost is sent as `null`, not omitted.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.date, forKey: .date)
        try container.encode(self.tool, forKey: .tool)
        try container.encode(self.model, forKey: .model)
        try container.encode(self.input_tokens, forKey: .input_tokens)
        try container.encode(self.cache_write_tokens, forKey: .cache_write_tokens)
        try container.encode(self.cache_read_tokens, forKey: .cache_read_tokens)
        try container.encode(self.output_tokens, forKey: .output_tokens)
        try container.encode(self.reasoning_tokens, forKey: .reasoning_tokens)
        try container.encode(self.requests, forKey: .requests)
        try container.encode(self.sessions, forKey: .sessions)
        try container.encode(self.reported_cost_cents, forKey: .reported_cost_cents)
    }
}

private struct ActivityPayload: Encodable {
    let intervals: [ActivityInterval]
}

private struct ActivityInterval: Encodable {
    // MARK: Lifecycle

    init(minute: PendingAgentActivity) {
        self.client_interval_id = minute.id
        self.tool = minute.tool.rawValue
        self.start_time = minute.startedAt
        self.end_time = minute.endedAt
        self.session_count = minute.sessionCount
        self.human_active = minute.humanActive
    }

    // MARK: Internal

    let client_interval_id: String
    let tool: String
    let start_time: Date
    let end_time: Date
    let session_count: Int
    let human_active: Bool
}

private extension Array {
    func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: self.count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, self.count)]) }
    }
}

// MARK: - Roots

/// The real home directory (not the sandbox container) and the log locations
/// under it. Reads are allowed by the home-relative sandbox exceptions.
struct AgentUsageRoots {
    // MARK: Lifecycle

    init() {
        let home = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        self.home = home
        self.claudeProjects = home + "/.claude/projects"
        self.codexSessions = home + "/.codex/sessions"
        // Codex moves finished sessions out of `sessions` and keeps them here.
        // On a working Mac this holds ten times as many transcripts, so a
        // reader that watches only `sessions` sees almost none of the usage.
        self.codexArchivedSessions = home + "/.codex/archived_sessions"
        self.cursorHome = home + "/.cursor"
        self.cursorGlobalStorage = home + "/Library/Application Support/Cursor/User/globalStorage"
        self.cursorDatabase = self.cursorGlobalStorage + "/state.vscdb"
        // opencode keeps its store under the XDG data directory. The sandbox
        // exception is home-relative, so the default location is the one that
        // can be read; a store moved with XDG_DATA_HOME is not.
        self.opencodeStorage = home + "/.local/share/opencode/storage"
        self.opencodeMessages = self.opencodeStorage + "/message"
    }

    // MARK: Internal

    let home: String
    let claudeProjects: String
    let codexSessions: String
    let codexArchivedSessions: String
    let cursorHome: String
    let cursorGlobalStorage: String
    let cursorDatabase: String
    let opencodeStorage: String
    let opencodeMessages: String

    var watchedDirectories: [String] {
        [
            self.claudeProjects,
            self.codexSessions,
            self.codexArchivedSessions,
            self.cursorHome,
            self.cursorGlobalStorage,
            self.opencodeMessages,
        ]
        .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Every directory a tool's transcripts can live in.
    func transcriptRoots(_ tool: AgentTool) -> [String] {
        switch tool {
        case .claudeCode: [self.claudeProjects]
        case .codex: [self.codexSessions, self.codexArchivedSessions]
        case .cursor: []
        case .opencode: [self.opencodeMessages]
        }
    }

    func displayLocation(_ tool: AgentTool) -> String {
        switch tool {
        case .claudeCode: "~/.claude"
        case .codex: "~/.codex"
        case .cursor: "~/Library/Application Support/Cursor"
        case .opencode: "~/.local/share/opencode"
        }
    }

    /// Readable and listable, which is what the sandbox exception has to grant.
    func isDetected(_ tool: AgentTool) -> Bool {
        switch tool {
        case .claudeCode,
             .codex,
             .opencode:
            return self.transcriptRoots(tool)
                .contains { (try? FileManager.default.contentsOfDirectory(atPath: $0)) != nil }
        case .cursor:
            return FileManager.default.isReadableFile(atPath: self.cursorDatabase)
        }
    }

    func transcriptTool(for path: String) -> AgentTool? {
        if path.hasSuffix(".jsonl") {
            if path.hasPrefix(self.claudeProjects + "/") { return .claudeCode }
            if path.hasPrefix(self.codexSessions + "/") || path.hasPrefix(self.codexArchivedSessions + "/") {
                return .codex
            }
            return nil
        }
        if path.hasSuffix(".json"), path.hasPrefix(self.opencodeMessages + "/") { return .opencode }
        return nil
    }

    func isCursorDatabase(_ path: String) -> Bool {
        path.hasPrefix(self.cursorDatabase)
    }
}

// MARK: - Scanner

/// Serial background worker: reads appended transcript bytes, applies the
/// parsers and writes aggregates through `Storage`. Storage opens a Realm per
/// call, so it is safe to use from here while the main actor reads.
actor AgentUsageScanner {
    // MARK: Lifecycle

    init(storage: Storage, tracker: Tracker, roots: AgentUsageRoots) {
        self.storage = storage
        self.tracker = tracker
        self.roots = roots
    }

    // MARK: Internal

    struct Outcome {
        var scanned = false
        var changed = false
        var events = 0
        var error: String?
    }

    /// Waits for whatever the actor is doing; used before deleting local rows.
    func settle() {}

    func scanAll(userID: String, since: Date) -> Outcome {
        var outcome = Outcome(scanned: true)
        var files: [String: AgentTool] = [:]
        for tool in AgentTool.allCases {
            for root in self.roots.transcriptRoots(tool) {
                for path in self.transcripts(under: root, tool: tool, modifiedAfter: since) { files[path] = tool }
            }
        }
        self.scan(files: files, userID: userID, since: since, into: &outcome)
        return outcome
    }

    func scan(files: [String: AgentTool], userID: String, since: Date) -> Outcome {
        var outcome = Outcome(scanned: true)
        self.scan(files: files, userID: userID, since: since, into: &outcome)
        return outcome
    }

    /// Forgets parse progress and the day rows inside the window, then scans
    /// everything again. Queued minutes are upserted, so they survive.
    func rebuild(userID: String, since: Date) -> Outcome {
        var outcome = Outcome(scanned: true)
        do {
            try self.storage.deleteAgentParseStates(for: userID)
            let dates = Set(
                (try self.storage.agentUsageDays(for: userID)).map(\.key.date)
                    .filter { $0 >= AgentUsageDates.localDate(since, calendar: .current) }
            )
            try self.storage.deleteAgentUsageDays(for: userID, dates: dates)
            self.cursorSignature = nil
            // Everything is read again from the first byte, so nothing has
            // been counted yet in this pass.
            self.seenMessages.removeAll(keepingCapacity: true)
            outcome.changed = true
        } catch {
            outcome.error = error.localizedDescription
            return outcome
        }
        var files: [String: AgentTool] = [:]
        for tool in AgentTool.allCases {
            for root in self.roots.transcriptRoots(tool) {
                for path in self.transcripts(under: root, tool: tool, modifiedAfter: since) { files[path] = tool }
            }
        }
        self.scan(files: files, userID: userID, since: since, into: &outcome)
        let cursor = self.readCursor(userID: userID, since: since, onlyIfChanged: false)
        outcome.changed = outcome.changed || cursor.changed
        outcome.error = outcome.error ?? cursor.error
        return outcome
    }

    func readCursor(userID: String, since: Date, onlyIfChanged: Bool) -> Outcome {
        var outcome = Outcome()
        let path = self.roots.cursorDatabase
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return outcome }
        let signature = "\(attributes[.modificationDate] ?? "")|\(attributes[.size] ?? "")"
        if onlyIfChanged, signature == self.cursorSignature { return outcome }
        outcome.scanned = true
        let rows = CursorUsageReader.read(databasePath: path, calendar: .current)
            .filter { $0.updatedAt >= since }
        var aggregator = AgentUsageAggregator(calendar: .current)
        for row in rows { aggregator.add(cursor: row) }
        do {
            try self.storage.replaceAgentUsage(
                for: userID,
                tool: .cursor,
                days: aggregator.days,
                sessionKeys: aggregator.sessionKeys
            )
            self.cursorSignature = signature
            outcome.changed = !aggregator.days.isEmpty
        } catch {
            outcome.error = error.localizedDescription
        }
        return outcome
    }

    // MARK: Private

    /// A message counted once stays counted for as long as the app runs. The
    /// ceiling is a safety valve, not an expectation: a month of heavy use is
    /// a few hundred thousand ids, and a rebuild starts the set over anyway.
    private static let seenMemoryLimit = 1_000_000

    private let storage: Storage
    private let tracker: Tracker
    private let roots: AgentUsageRoots
    private var cursorSignature: String?
    /// Every `message.id|requestId` this scanner has already counted.
    private var seenMessages: Set<String> = []

    private func transcripts(under root: String, tool: AgentTool, modifiedAfter since: Date) -> [String] {
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension == tool.transcriptExtension {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= since else { continue }
            paths.append(url.path)
        }
        return paths
    }

    private func scan(files: [String: AgentTool], userID: String, since: Date, into outcome: inout Outcome) {
        guard !files.isEmpty else { return }
        var aggregator = AgentUsageAggregator(calendar: .current)
        var states: [AgentParseState] = []
        for (path, tool) in files {
            do {
                guard var state = try self.parseState(for: path, tool: tool, userID: userID) else { continue }
                let events = try self.parse(path: path, state: &state)
                aggregator.add(contentsOf: events.filter { $0.timestamp >= since })
                outcome.events += events.count
                states.append(state)
            } catch {
                outcome.error = error.localizedDescription
            }
        }
        do {
            try self.storage.store(parseStates: states)
            guard !aggregator.isEmpty else { return }
            try self.storage.mergeAgentUsage(for: userID, days: aggregator.days, sessionKeys: aggregator.sessionKeys)
            let minutes = aggregator.minutes.map { minute in
                PendingAgentActivity(
                    minuteID: minute.minuteStart.id,
                    startedAt: minute.minuteStart,
                    endedAt: minute.minuteStart.addingTimeInterval(60),
                    tool: minute.tool,
                    sessionCount: minute.sessionCount,
                    humanActive: self.tracker.wasHumanActive(minuteStart: minute.minuteStart),
                    userID: userID
                )
            }
            try self.storage.store(agentActivity: minutes)
            outcome.changed = true
        } catch {
            outcome.error = error.localizedDescription
        }
    }

    /// Returns nil when the file did not grow since the last pass.
    private func parseState(for path: String, tool: AgentTool, userID: String) throws -> AgentParseState? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = attributes[.modificationDate] as? Date
        var state = try self.storage.agentParseState(id: AgentParseState.id(userID: userID, path: path))
            ?? AgentParseState(userID: userID, path: path, tool: tool)
        if state.offset > size {
            // Rewritten or truncated: start over for this file.
            state.offset = 0
            state.seenIDs = []
            state.codex = CodexCumulative()
        }
        guard size > state.offset || modified != state.lastModified else { return nil }
        state.lastModified = modified
        state.fileSize = size
        return state
    }

    private func parse(path: String, state: inout AgentParseState) throws -> [AgentUsageEvent] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        // opencode rewrites a message in place, so its file is read whole;
        // the append-only transcripts resume where the last pass stopped.
        try handle.seek(toOffset: state.tool == .opencode ? 0 : UInt64(state.offset))
        guard let data = try handle.readToEnd(), !data.isEmpty else { return [] }
        let sessionKey = state.sessionKey
        switch state.tool {
        case .claudeCode:
            // One set for every file this scanner reads, not one per file.
            // Resuming a session writes a new transcript that repeats the
            // earlier messages, ids and all, in the same project directory;
            // a per-file set counted every one of them a second time.
            self.seenMessages.formUnion(state.seenIDs)
            if self.seenMessages.count > Self.seenMemoryLimit { self.seenMessages.removeAll(keepingCapacity: true) }
            let result = ClaudeUsageParser.parse(
                data: data,
                from: 0,
                sessionKey: sessionKey,
                seen: &self.seenMessages
            )
            state.offset += result.consumedOffset
            // The shared set is the authority now; a file keeps none of its
            // own. Offsets already stop a file from being read twice.
            state.seenIDs = []
            return result.events
        case .codex:
            var cumulative = state.codex
            let result = CodexUsageParser.parse(data: data, from: 0, sessionKey: sessionKey, state: &cumulative)
            state.offset += result.consumedOffset
            state.codex = cumulative
            return result.events
        case .opencode:
            // One message per file, rewritten in place until the turn ends, so
            // the id it was counted under is kept beside the file: a later
            // rewrite of a message already counted adds nothing.
            var seen = Set(state.seenIDs)
            let events = OpencodeUsageParser.parse(data: data, seen: &seen)
            state.offset = data.count
            state.seenIDs = Array(seen)
            return events
        case .cursor:
            return []
        }
    }
}

// MARK: - FSEvents

/// One file-level FSEvents stream over the watched directories, delivered on a
/// private queue with a two second latency so bursts coalesce.
final class AgentLogWatcher {
    // MARK: Lifecycle

    init(paths: [String], handler: @escaping ([String]) -> Void) {
        self.paths = paths
        self.handler = handler
    }

    deinit {
        self.stop()
    }

    // MARK: Internal

    func start() {
        guard self.stream == nil, !self.paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<AgentLogWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(eventPaths, to: NSArray.self)
            let paths = (0 ..< count).compactMap { array[$0] as? String }
            watcher.handler(paths)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            self.paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, self.queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: Private

    private let paths: [String]
    private let handler: ([String]) -> Void
    private let queue = DispatchQueue(label: "firstlight.agent-usage.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
}

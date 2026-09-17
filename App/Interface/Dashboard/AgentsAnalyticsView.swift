import SwiftUI

/// What is read out of a person's last thirty days for the Agents screen:
/// the streak and the records. Pure, so the screen only draws, and thirty
/// days whatever the period, so neither changes with the zoom.
enum AgentAnalytics {
    struct Streak: Equatable {
        struct Mark: Equatable, Identifiable {
            /// The day, as the server names it.
            let id: String
            let minutes: Double
            let running: Bool

            var worked: Bool { self.minutes > 0 }
        }

        /// Days in a row with agent time, ending today — or yesterday, while
        /// today has none yet: a day that is not over has not broken anything.
        let current: Int
        let best: Int
        /// The first day of the current streak.
        let since: String?
        /// The streak reaches the far edge of what was asked for, so it may
        /// be longer than the number says.
        let fillsWindow: Bool
        /// One mark per day, oldest first: worked or not, and whether the day
        /// belongs to the streak that is running.
        let marks: [Mark]
    }

    struct Record: Identifiable, Equatable {
        let id: String
        let title: String
        let value: String
        let note: String
        /// The day the record was set, when the day can be opened: one whose
        /// runs were shared.
        let date: String?
    }

    /// The streak as the server counted it over all it has, drawn on the
    /// thirty days in hand; or counted from those days alone, where the
    /// server is older than the figure.
    static func streak(_ month: NativeAgentSummary?) -> Streak {
        let counted = self.streak(month?.days ?? [])
        guard let stored = month?.streak else { return counted }
        return Streak(
            current: stored.current, best: stored.best, since: stored.since,
            fillsWindow: false, marks: counted.marks
        )
    }

    static func streak(_ days: [NativeAgentSummary.Day]) -> Streak {
        let worked = days.map { $0.agent_minutes > 0 }
        var best = 0, run = 0
        for day in worked {
            run = day ? run + 1 : 0
            best = max(best, run)
        }
        var end = worked.count - 1
        if end >= 0, !worked[end] { end -= 1 }
        var start = end
        while start >= 0, worked[start] { start -= 1 }
        let current = max(end - start, 0)
        let first = start + 1
        return Streak(
            current: current,
            best: best,
            since: current > 0 ? days[first].date : nil,
            fillsWindow: current > 0 && first == 0,
            marks: days.enumerated().map { index, day in
                .init(id: day.date, minutes: day.agent_minutes, running: current > 0 && index >= first && index <= end)
            }
        )
    }

    static func records(_ month: NativeAgentSummary) -> [Record] {
        let days = month.days ?? []
        var records: [Record] = []
        let runs = days.flatMap { day in (day.runs ?? []).map { (day: day, run: $0) } }

        if let peak = runs.max(by: { ($0.run.peak_sessions ?? 1) < ($1.run.peak_sessions ?? 1) }),
           (peak.run.peak_sessions ?? 1) > 1
        {
            records.append(Record(
                id: "peak", title: "Most at once", value: "×\(peak.run.peak_sessions ?? 1)",
                note: "\(NativeAgentTime.shortDate(peak.day.date)) · \(NativeAgentToolLabel.name(peak.run.tool))",
                date: peak.day.date
            ))
        } else if runs.isEmpty, let most = month.max_concurrency, most > 1 {
            records.append(Record(id: "peak", title: "Most at once", value: "×\(most)", note: "sessions", date: nil))
        }

        if let longest = runs.max(by: { $0.run.minutes < $1.run.minutes }) {
            records.append(Record(
                id: "run", title: "Longest run", value: DurationLabel.minutes(longest.run.minutes),
                note: "\(NativeAgentTime.shortDate(longest.day.date)) · \(NativeAgentToolLabel.name(longest.run.tool))",
                date: longest.day.date
            ))
        } else if let minutes = month.longest_run_minutes, minutes > 0 {
            records.append(Record(
                id: "run", title: "Longest run", value: DurationLabel.minutes(minutes), note: "one sitting", date: nil
            ))
        }

        if let biggest = days.max(by: { $0.agent_minutes < $1.agent_minutes }), biggest.agent_minutes > 0 {
            records.append(Record(
                id: "day", title: "Biggest day", value: DurationLabel.minutes(biggest.agent_minutes),
                note: NativeAgentTime.shortDate(biggest.date),
                date: biggest.runs?.isEmpty == false ? biggest.date : nil
            ))
        }

        if let heaviest = days.max(by: { ($0.tokens_total ?? 0) < ($1.tokens_total ?? 0) }),
           let tokens = heaviest.tokens_total, tokens > 0
        {
            let cost = heaviest.cost_usd.flatMap { $0 > 0 ? " · " + AgentAmountLabel.usd($0) : nil } ?? ""
            records.append(Record(
                id: "tokens", title: "Most tokens in a day", value: AgentAmountLabel.tokens(tokens),
                note: NativeAgentTime.shortDate(heaviest.date) + cost,
                date: heaviest.runs?.isEmpty == false ? heaviest.date : nil
            ))
        }
        return records
    }
}

/// Large amounts in the few characters a tile has: "19B", "2.1B", "768M",
/// and dollars without cents once cents stop meaning anything.
enum AgentAmountLabel {
    static func tokens(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        for (size, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where value >= size {
            let scaled = value / size
            return (scaled < 10 ? String(format: "%.1f", scaled) : String(Int(scaled.rounded()))) + suffix
        }
        return String(Int(value.rounded()))
    }

    static func usd(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "$0" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = value < 100 ? 2 : 0
        formatter.maximumFractionDigits = value < 100 ? 2 : 0
        return "$" + (formatter.string(from: NSNumber(value: value)) ?? String(Int(value)))
    }
}

/// Thirty days of what the tokens come to at API rates, a bar a day: today's
/// figure, the month's, and any day under the pointer. Where the server gives
/// no estimate — a person sharing only totals, or an older server — the same
/// card is about the tokens themselves.
struct AgentSpendCard: View {
    // MARK: Internal

    let month: NativeAgentSummary

    var body: some View {
        let days = self.month.days ?? []
        let priced = self.month.cost_usd != nil
        let values = days.map { priced ? ($0.cost_usd ?? 0) : ($0.tokens_total ?? 0) }
        let scale = max(values.max() ?? 0, priced ? 0.01 : 1)
        let peak = values.indices.max { values[$0] < values[$1] }
        let today = days.last
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                self.figure(
                    self.hovered.flatMap { days[safe: $0] }.map { NativeAgentTime.dayLabel($0.date) } ?? "Today",
                    day: self.hovered.flatMap { days[safe: $0] } ?? today, priced: priced
                )
                self.figure(
                    "30 days",
                    amount: priced ? AgentAmountLabel.usd(self.month.cost_usd ?? 0) :
                        AgentAmountLabel.tokens(self.month.tokens?.total ?? 0),
                    detail: priced ? AgentAmountLabel.tokens(self.month.tokens?.total ?? 0) + " tokens" : "tokens"
                )
            }
            VStack(spacing: 5) {
                GeometryReader { geometry in
                    let pitch = geometry.size.width / CGFloat(max(days.count, 1))
                    ZStack(alignment: .topLeading) {
                        HStack(alignment: .bottom, spacing: 2) {
                            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                                let height = values[index] > 0 ? max(Self.chartHeight * values[index] / scale, 2) : 0
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                        .fill(Color.firstlight)
                                        .frame(height: height)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: Self.chartHeight, alignment: .bottom)
                                .background(alignment: .bottom) {
                                    Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1)
                                }
                                .opacity(self.hovered.map { $0 != index } ?? false ? 0.4 : 1)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(self.spoken(day, priced: priced))
                            }
                        }
                        .offset(y: Self.labelRoom)
                        // The tallest day says what it held, until the pointer
                        // is reading the days itself.
                        if let peak, values[peak] > 0 {
                            Text(priced ? AgentAmountLabel.usd(values[peak]) : AgentAmountLabel.tokens(values[peak]))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.9))
                                .fixedSize()
                                .frame(width: 60)
                                .offset(
                                    x: min(max(pitch * (CGFloat(peak) + 0.5) - 30, -8), geometry.size.width - 52),
                                    y: -1
                                )
                                .opacity(self.hovered == nil ? 1 : 0)
                        }
                    }
                    .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: self.hovered)
                    // The stack is as tall as what it lays out, and the bars
                    // are drawn 12 pt below that by an offset, which moves
                    // the picture and not the frame. Without its own frame
                    // the pointer was read over the empty strip above the
                    // bars and not over their lower part.
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(point):
                            self.hovered = min(max(Int(point.x / max(pitch, 1)), 0), days.count - 1)
                        case .ended:
                            self.hovered = nil
                        }
                    }
                }
                .frame(height: Self.labelRoom + Self.chartHeight)
                HStack {
                    Text(days.first.map { NativeAgentTime.shortDate($0.date) } ?? "")
                    Spacer(minLength: 0)
                    Text("today")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.55))
                .accessibilityHidden(true)
            }
            Text(
                !priced ? "Every token the requests carried, by day." :
                    self.month.cost_partial == true ? "Estimated at API rates, without unpriced models." :
                    "Estimated from tokens at API rates, not a bill."
            )
            .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Private

    private static let chartHeight: CGFloat = 44
    private static let labelRoom: CGFloat = 12

    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func figure(_ title: String, day: NativeAgentSummary.Day?, priced: Bool) -> some View {
        let tokens = AgentAmountLabel.tokens(day?.tokens_total ?? 0)
        return self.figure(
            title,
            amount: priced ? AgentAmountLabel.usd(day?.cost_usd ?? 0) : tokens,
            detail: priced ? tokens + " tokens" : "tokens"
        )
    }

    private func figure(_ title: String, amount: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.65))
                .contentTransition(.opacity)
            Text(amount).font(.system(size: 20, weight: .medium)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.22, extraBounce: 0), value: amount)
            Text(detail).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.55))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spoken(_ day: NativeAgentSummary.Day, priced: Bool) -> String {
        let tokens = AgentAmountLabel.tokens(day.tokens_total ?? 0) + " tokens"
        return NativeAgentTime.dayLabel(day.date) + ": " +
            (priced ? AgentAmountLabel.usd(day.cost_usd ?? 0) + ", " + tokens : tokens)
    }
}

/// The days in a row with agent time, as a number and as the thirty marks it
/// was counted from, the running stretch in the agents' colour.
struct AgentStreakSection: View {
    // MARK: Internal

    let streak: AgentAnalytics.Streak

    var body: some View {
        let pointed = self.hovered.flatMap { index in
            self.streak.marks.indices.contains(index) ? self.streak.marks[index] : nil
        }
        VStack(alignment: .leading, spacing: 8) {
            // The line beside the number is about the streak until the
            // pointer is on a day, and then about that day: which one it
            // was and how long the agents ran, in the place the eye is
            // already reading.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.headline).font(.system(size: 20, weight: .medium)).monospacedDigit()
                Text(pointed.map(self.dayLine) ?? self.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(pointed == nil ? 0.55 : 0.9))
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: self.hovered)
            }
            GeometryReader { geometry in
                let pitch = geometry.size.width / CGFloat(max(self.streak.marks.count, 1))
                HStack(spacing: 2) {
                    ForEach(Array(self.streak.marks.enumerated()), id: \.element.id) { index, mark in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(
                                mark.running ? AnyShapeStyle(Color.firstlight) :
                                    AnyShapeStyle(Color.primary.opacity(mark.worked ? 0.32 : 0.07))
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 10)
                            .opacity(self.hovered.map { $0 != index } ?? false ? 0.45 : 1)
                    }
                }
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: self.hovered)
                // One target over the row, with room above and below it: the
                // marks are 10 pt tall and a pointer should not have to aim.
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(point):
                        self.hovered = min(max(Int(point.x / max(pitch, 1)), 0), self.streak.marks.count - 1)
                    case .ended:
                        self.hovered = nil
                    }
                }
                .padding(.vertical, -6)
            }
            .frame(height: 10)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Private

    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var headline: String {
        guard self.streak.current > 0 else { return "No streak" }
        return "\(self.streak.current)\(self.streak.fillsWindow ? "+" : "") day\(self.streak.current == 1 ? "" : "s")"
    }

    private var detail: String {
        guard self.streak.current > 0 else {
            return self.streak.best > 0 ? "right now · best \(self.streak.best) days" : "yet"
        }
        var parts = ["in a row"]
        if self.streak.best > self.streak.current { parts.append("best \(self.streak.best)") }
        if let since = self.streak.since, !self.streak.fillsWindow {
            parts.append("since \(NativeAgentTime.shortDate(since))")
        }
        return parts.joined(separator: " · ")
    }

    private func dayLine(_ mark: AgentAnalytics.Streak.Mark) -> String {
        NativeAgentTime.dayLabel(mark.id) + " · " +
            (mark.worked ? DurationLabel.minutes(mark.minutes) + " of agents" : "no agents")
    }
}

/// The records as tiles, two across. A tile whose day can be opened is a
/// button, and its frame is what the day's tray opens out of: while the tray
/// is open the tile keeps its room and gives up its fill.
struct AgentRecordTiles: View {
    // MARK: Internal

    let records: [AgentAnalytics.Record]
    /// The tile whose day is open, if one is.
    let openSource: String?
    /// Where each tile stands in the popover, kept for the tray to grow out
    /// of. A box and not state: it changes with every scroll tick and nothing
    /// is drawn from it until a tile is pressed.
    let frames: AgentTileFrames
    let open: (AgentAnalytics.Record) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(self.records) { record in
                if record.date != nil {
                    Button { self.open(record) } label: { self.tile(record) }
                        .buttonStyle(ProfileTileStyle())
                        .onHover { inside in
                            if inside { self.hovered = record.id }
                            else if self.hovered == record.id { self.hovered = nil }
                        }
                        .help("Open \(record.note)")
                } else {
                    self.tile(record)
                }
            }
        }
    }

    // MARK: Private

    /// The tile under the pointer, among those that open.
    @State private var hovered: String?

    private func tile(_ record: AgentAnalytics.Record) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.title).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.65)).lineLimit(1)
            Text(record.value).font(.system(size: 16, weight: .medium)).monospacedDigit().lineLimit(1)
            Text(record.note).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.55)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        // A tile that opens its day says so the way the card says More: a
        // chevron in the corner, and a surface that answers the pointer.
        .overlay(alignment: .topTrailing) {
            if record.date != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(self.hovered == record.id ? 0.9 : 0.45))
                    .padding(.top, 13).padding(.trailing, 11)
                    .accessibilityHidden(true)
            }
        }
        // Open, the tile is the tray: its title has gone up into the tray's
        // header, so nothing of it stays behind under the veil.
        .opacity(self.openSource == record.id ? 0 : 1)
        .background {
            if self.openSource != record.id {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(self.hovered == record.id ? 0.1 : 0.055))
            }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(AgentTileFrames.space)) }) { frame in
            self.frames.frames[record.id] = frame
        }
        .animation(.easeOut(duration: 0.12), value: self.hovered == record.id)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The record tiles' frames in the popover's own space.
final class AgentTileFrames {
    static let space = "agents-popover"
    /// A tile's padding: where its title begins inside its frame.
    static let titleInset: CGFloat = 10
    /// The tile's title is 11 pt and the tray's 13.
    static let titleScale: CGFloat = 11 / 13

    var frames: [String: CGRect] = [:]
}

/// How the day's tray arrives: its surface opens out of the tile that was
/// pressed and closes back into it. The tray is laid out at its full size
/// from the first frame and revealed by a shape that travels from the tile's
/// frame to the tray's, so nothing inside is stretched on the way. A tile in
/// a lazy grid inside a scroll view does not take part in matched geometry,
/// which is why the travel is done by hand.
struct AgentTrayGrow: ViewModifier, Animatable {
    var progress: Double
    let source: CGRect?
    /// On the way out the tray fades to nothing as it reaches the tile, which
    /// has its own fill back by then. On the way in it starts at a third, so
    /// the tile does not blink out before its surface has begun to open.
    var closing = false

    var animatableData: Double {
        get { self.progress }
        set { self.progress = newValue }
    }

    /// Opening is the tray spring. Closing is a curve with an end: a spring
    /// keeps the view alive until it has settled, and for its last stretch it
    /// barely moves, so the tray stood at the tile's size for a few frames and
    /// then vanished, which read as a stall.
    static func animation(opening: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.12) }
        return opening ? .spring(duration: 0.24, bounce: 0) : .timingCurve(0.4, 0, 0.2, 1, duration: 0.2)
    }

    func body(content: Content) -> some View {
        content
            .mask {
                GeometryReader { geometry in
                    let full = geometry.frame(in: .named(AgentTileFrames.space))
                    let from = self.source ?? full
                    let t = CGFloat(self.progress)
                    let width = from.width + (full.width - from.width) * t
                    let height = from.height + (full.height - from.height) * t
                    let midX = from.midX + (full.midX - from.midX) * t - full.minX
                    let midY = from.midY + (full.midY - from.midY) * t - full.minY
                    RoundedRectangle(cornerRadius: 12 + 4 * t, style: .continuous)
                        .frame(width: max(width, 1), height: max(height, 1))
                        .position(x: midX, y: midY)
                }
            }
            .opacity(
                self.source == nil ? self.progress :
                    self.closing ? min(1, self.progress * 2.5) : min(1, 0.35 + self.progress * 2)
            )
            .shadow(color: .black.opacity(0.16 * self.progress), radius: 18, y: 6)
    }
}

/// The models behind the period, each as its share of the tokens in its
/// tool's colour, with what that share comes to.
struct AgentModelsSection: View {
    let models: [NativeAgentSummary.ModelUsage]

    var body: some View {
        let shown = Array(self.models.prefix(6))
        let total = self.models.reduce(0) { $0 + $1.tokens_total }
        if !shown.isEmpty, total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Models").font(.system(size: 12, weight: .semibold))
                VStack(spacing: 7) {
                    ForEach(shown) { model in
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Text(model.model).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(AgentAmountLabel.tokens(model.tokens_total))
                                    .foregroundStyle(Color.primary.opacity(0.55))
                                if let cost = model.cost_usd, cost > 0 {
                                    Text(AgentAmountLabel.usd(cost)).frame(minWidth: 52, alignment: .trailing)
                                }
                            }
                            .font(.system(size: 11)).monospacedDigit()
                            GeometryReader { geometry in
                                Capsule().fill(NativeAgentToolColor.color(model.tool))
                                    .frame(width: max(geometry.size.width * model.tokens_total / total, 2))
                            }
                            .frame(height: 3)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// The tools, each with how long it ran, in how many sessions, and the model
/// it leaned on.
struct AgentToolsSection: View {
    // MARK: Internal

    let tools: [NativeAgentSummary.ToolUsage]

    var body: some View {
        let shown = self.tools.filter { ($0.agent_minutes ?? 0) > 0 || $0.tokens_total > 0 }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tools").font(.system(size: 12, weight: .semibold))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, tool in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(NativeAgentToolColor.color(tool.tool))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(NativeAgentToolLabel.name(tool.tool)).font(.system(size: 12))
                                Text(self.detail(tool)).font(.system(size: 11))
                                    .foregroundStyle(Color.primary.opacity(0.55)).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(DurationLabel.minutes(tool.agent_minutes ?? 0))
                                .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                        if index < shown.count - 1 { Divider().opacity(0.5) }
                    }
                }
            }
        }
    }

    // MARK: Private

    private func detail(_ tool: NativeAgentSummary.ToolUsage) -> String {
        var parts: [String] = []
        if let sessions = tool.sessions,
           sessions > 0 { parts.append("\(sessions.formatted()) session\(sessions == 1 ? "" : "s")") }
        if tool.tokens_total > 0 { parts.append(AgentAmountLabel.tokens(tool.tokens_total) + " tokens") }
        if let model = tool.top_model { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

/// One day inside its tray: the half-hour columns the profile draws for
/// today, and under them the runs long enough to have been a sitting.
struct AgentDayTrayContent: View {
    // MARK: Internal

    let day: NativeAgentSummary.Day

    var body: some View {
        let runs = (self.day.runs ?? []).filter { $0.minutes >= 15 }.sorted { $0.minutes > $1.minutes }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                self.figure("Active time", minutes: self.hovered?.human ?? self.day.human_minutes)
                self.figure("Agents", minutes: self.hovered?.agent ?? self.day.agent_minutes)
            }
            ProfileDayColumns(day: self.day, hovered: self.$hovered)
            if !runs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(runs.prefix(6).enumerated()), id: \.element.id) { index, run in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(NativeAgentToolColor.color(run.tool))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(
                                    "\(NativeAgentTime.clock(run.start_time)) – \(NativeAgentTime.clock(run.end_time))"
                                )
                                .font(.system(size: 12)).monospacedDigit()
                                Text(self.detail(run)).font(.system(size: 11))
                                    .foregroundStyle(Color.primary.opacity(0.55)).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(DurationLabel.minutes(run.minutes))
                                .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                        if index < min(runs.count, 6) - 1 { Divider().opacity(0.5) }
                    }
                }
            }
        }
    }

    // MARK: Private

    @State private var hovered: AgentBucket?

    private func figure(_ title: String, minutes: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.65))
            AnimatedDuration(minutes: minutes, animation: .snappy(duration: 0.22, extraBounce: 0))
                .font(.system(size: 20, weight: .medium))
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ run: NativeAgentSummary.Run) -> String {
        let peak = run.peak_sessions ?? 1
        return NativeAgentToolLabel.name(run.tool) + (peak > 1 ? " · ×\(peak) at the peak" : "")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { self.indices.contains(index) ? self[index] : nil }
}

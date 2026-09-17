#if DEBUG
import AppKit
import Darwin
import os

/// Developer mode for performance: a small readout, over every window and every
/// space, of what this process costs right now. CPU for the whole app; CPU on
/// the main thread alone, where a layout or focus loop shows first; how late the
/// main thread answers; memory; and the last minute drawn under the numbers.
/// It never takes a click or the keyboard. Off by default, compiled out of
/// Release, toggled from the status item's menu or `--performance-hud`.
@MainActor
enum PerformanceHUD {
    // MARK: Internal

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: self.defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: self.defaultsKey)
            if newValue { self.show() } else { self.hide() }
        }
    }

    /// At launch. `--performance-hud` turns it on and it stays on.
    static func restore() {
        if CommandLine.arguments.contains("--performance-hud") {
            UserDefaults.standard.set(true, forKey: self.defaultsKey)
        }
        if self.isEnabled { self.show() }
    }

    // MARK: Private

    private static let defaultsKey = "firstlight.debug.performanceHUD"
    private static let size = NSSize(width: 164, height: 70)

    private static var panel: NSPanel?
    private static var view: PerformanceHUDView?
    private static var monitor: PerformanceMonitor?
    private static var mainThread: thread_act_t = 0
    private static var screenObserver: NSObjectProtocol?

    private static func show() {
        guard self.panel == nil else { return }
        let view = PerformanceHUDView(frame: NSRect(origin: .zero, size: self.size))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Firstlight Performance HUD"
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.panel = panel
        self.view = view
        self.place()
        panel.orderFrontRegardless()
        self.screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { self.place() } }

        // The main thread's port is only reachable from the main thread itself.
        self.mainThread = mach_thread_self()
        let monitor = PerformanceMonitor(mainThread: self.mainThread) { sample in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.view?.show(sample) } }
        }
        monitor.start()
        self.monitor = monitor
    }

    private static func hide() {
        self.monitor?.stop()
        self.monitor = nil
        if self.mainThread != 0 {
            mach_port_deallocate(mach_task_self_, self.mainThread)
            self.mainThread = 0
        }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        self.screenObserver = nil
        self.panel?.orderOut(nil)
        self.panel = nil
        self.view = nil
    }

    /// The lower right corner of the screen with the menu bar, clear of the
    /// popover, which hangs from the top.
    private static func place() {
        guard let panel, let area = NSScreen.screens.first?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: area.maxX - self.size.width - 12, y: area.minY + 12))
    }
}

/// Samples on its own queue, so a busy main thread cannot hide its own cost.
private final class PerformanceMonitor: @unchecked Sendable {
    // MARK: Lifecycle

    init(mainThread: thread_act_t, report: @escaping @Sendable (Sample) -> Void) {
        self.mainThread = mainThread
        self.report = report
    }

    // MARK: Internal

    struct Sample {
        /// Percent of one core, so a spinning thread reads 100.
        let processCPU: Double
        let mainCPU: Double
        /// Seconds: the longest a block posted to the main queue waited.
        let mainLag: Double
        let footprint: UInt64
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now(), repeating: Self.pingInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        self.timer?.cancel()
        self.timer = nil
    }

    // MARK: Private

    private static let pingInterval = 0.1
    private static let pingsPerSample = 5
    private static let log = Logger(subsystem: "sh.firstlight.mac", category: "PerformanceHUD")

    private let queue = DispatchQueue(label: "sh.firstlight.performance-hud", qos: .utility)
    private let mainThread: thread_act_t
    private let report: @Sendable (Sample) -> Void
    private let worstLag = OSAllocatedUnfairLock(initialState: 0.0)
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var last: (wall: Double, process: Double, main: Double)?
    private var busySince: Double?
    private var busyLogged = false

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    private static func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }

    private static func seconds(_ time: time_value_t) -> Double {
        Double(time.seconds) + Double(time.microseconds) / 1e6
    }

    private static func processCPUTime() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return self.seconds(usage.ru_utime) + self.seconds(usage.ru_stime)
    }

    private static func threadCPUTime(_ thread: thread_act_t) -> Double? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return self.seconds(info.user_time) + self.seconds(info.system_time)
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func tick() {
        let sent = Self.now()
        DispatchQueue.main.async { [worstLag] in
            let lag = PerformanceMonitor.now() - sent
            worstLag.withLock { $0 = max($0, lag) }
        }
        self.ticks += 1
        guard self.ticks % Self.pingsPerSample == 0 else { return }

        let wall = Self.now()
        let process = Self.processCPUTime()
        let main = Self.threadCPUTime(self.mainThread) ?? 0
        defer { self.last = (wall, process, main) }
        guard let last = self.last else { return }
        let elapsed = max(wall - last.wall, 0.001)
        let lag = self.worstLag.withLock { value in
            defer { value = 0 }
            return value
        }
        let sample = Sample(
            processCPU: 100 * (process - last.process) / elapsed,
            mainCPU: 100 * (main - last.main) / elapsed,
            mainLag: lag,
            footprint: Self.footprint()
        )
        self.note(sample, at: wall)
        self.report(sample)
    }

    /// A main thread that stays near a full core earns a line in the log, so a
    /// loop can be found afterwards even when nobody was watching the HUD.
    private func note(_ sample: Sample, at time: Double) {
        guard sample.mainCPU >= 90 else {
            if let busySince, self.busyLogged {
                let duration = time - busySince
                Self.log.notice("Main thread busy period ended after \(duration, format: .fixed(precision: 1)) s")
            }
            self.busySince = nil
            self.busyLogged = false
            return
        }
        let since = self.busySince ?? time
        self.busySince = since
        if !self.busyLogged, time - since >= 3 {
            self.busyLogged = true
            let percent = Int(sample.mainCPU)
            Self.log.warning("Main thread at \(percent)% for 3 s or more")
        }
    }
}

/// The numbers over a minute of history: the whole app as a line, the main
/// thread as the filled area under it.
private final class PerformanceHUDView: NSVisualEffectView {
    // MARK: Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.material = .hudWindow
        self.blendingMode = .behindWindow
        self.state = .active
        self.wantsLayer = true
        self.layer?.cornerRadius = 10
        self.layer?.cornerCurve = .continuous
        self.layer?.masksToBounds = true
        self.label.maximumNumberOfLines = 2
        self.label.frame = NSRect(x: 10, y: frame.height - 38, width: frame.width - 20, height: 30)
        self.addSubview(self.label)
        self.chart.frame = NSRect(x: 10, y: 8, width: frame.width - 20, height: 20)
        self.addSubview(self.chart)
        self.label.attributedStringValue = Self.text(nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    func show(_ sample: PerformanceMonitor.Sample) {
        self.label.attributedStringValue = Self.text(sample)
        self.chart.append(process: sample.processCPU, main: sample.mainCPU)
    }

    // MARK: Private

    private let label = NSTextField(labelWithString: "")
    private let chart = PerformanceChartView()

    private static func text(_ sample: PerformanceMonitor.Sample?) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let result = NSMutableAttributedString()
        func add(_ string: String, _ color: NSColor = .secondaryLabelColor) {
            result.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        guard let sample else {
            add("CPU    –  main   –\nlag    –       –")
            return result
        }
        let lag = sample.mainLag * 1000
        add("CPU ")
        add(String(format: "%4.0f%%", sample.processCPU), .labelColor)
        add("  main ")
        add(String(format: "%3.0f%%", sample.mainCPU), self.level(sample.mainCPU, warn: 40, alarm: 80))
        add("\nlag ")
        add(String(format: "%4.0f ms", lag), self.level(lag, warn: 50, alarm: 250))
        add(String(format: " %4.0f MB", Double(sample.footprint) / 1_048_576), .labelColor)
        return result
    }

    private static func level(_ value: Double, warn: Double, alarm: Double) -> NSColor {
        value >= alarm ? .systemRed : value >= warn ? .systemOrange : .labelColor
    }
}

private final class PerformanceChartView: NSView {
    // MARK: Internal

    /// Two samples a second: a minute.
    static let capacity = 120

    override var isFlipped: Bool { false }

    func append(process: Double, main: Double) {
        self.process.append(process)
        self.main.append(main)
        if self.process.count > Self.capacity { self.process.removeFirst() }
        if self.main.count > Self.capacity { self.main.removeFirst() }
        self.needsDisplay = true
    }

    override func draw(_: NSRect) {
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 0.5)).fill()
        guard self.main.count > 1 else { return }
        let step = bounds.width / CGFloat(Self.capacity - 1)
        let offset = CGFloat(Self.capacity - self.main.count) * step
        func y(_ percent: Double) -> CGFloat { bounds.height * CGFloat(min(max(percent, 0), 100) / 100) }

        let area = NSBezierPath()
        area.move(to: NSPoint(x: offset, y: 0))
        for (index, value) in self.main.enumerated() {
            area.line(to: NSPoint(x: offset + CGFloat(index) * step, y: y(value)))
        }
        area.line(to: NSPoint(x: offset + CGFloat(self.main.count - 1) * step, y: 0))
        area.close()
        NSColor.systemOrange.withAlphaComponent(0.45).setFill()
        area.fill()

        let line = NSBezierPath()
        for (index, value) in self.process.enumerated() {
            let point = NSPoint(x: offset + CGFloat(index) * step, y: y(value))
            if index == 0 { line.move(to: point) } else { line.line(to: point) }
        }
        line.lineWidth = 1
        NSColor.white.withAlphaComponent(0.85).setStroke()
        line.stroke()
    }

    // MARK: Private

    private var process: [Double] = []
    private var main: [Double] = []
}
#endif

import AppKit
import Foundation
import ServiceManagement

final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let temperature = TemperatureMonitor()
    private let sampler = EnergySampler()
    private let gpuQueue = DispatchQueue(label: "heatwatch.gpu", qos: .utility)
    private var gpuBaseline: [pid_t: UInt64] = [:]

    private var dotImages: [HeatLevel: NSImage] = [:]
    private var liveRefreshTimer: Timer?
    private var backgroundBaselineTimer: Timer?
    private var headerItem: NSMenuItem?
    private var gpuHeaderItem: NSMenuItem?
    private var powerHeaderItem: NSMenuItem?
    private var rowItems: [NSMenuItem] = []
    private var gpuRowItems: [NSMenuItem] = []
    private var gpuCaptionItem: NSMenuItem?
    private var energyCaptionItem: NSMenuItem?
    private var gpuSectionSeparator: NSMenuItem?
    private var measuringItem: NSMenuItem?
    private var idleItem: NSMenuItem?
    private var totalItem: NSMenuItem?
    private var lastReading: TemperatureMonitor.Reading?
    private var lastReport: EnergySampler.Report?
    private var lastReportAt: Date?
    private var reportPending = false
    private var menuIsOpen = false
    private var currentLevel: HeatLevel = .cool

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        for level in [HeatLevel.cool, .warm, .hot] {
            dotImages[level] = Self.dotImage(for: level)
        }

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "HeatWatch"
        statusItem.behavior = .removalAllowed

        apply(level: .cool)

        temperature.onUpdate = { [weak self] reading in
            self?.handle(reading)
        }
        temperature.start()

        sampler.refreshBaseline()
        backgroundBaselineTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.sampler.refreshBaseline()
        }
        backgroundBaselineTimer?.tolerance = 5
    }

    func shutdown() {
        temperature.stop()
        liveRefreshTimer?.invalidate()
        backgroundBaselineTimer?.invalidate()
    }

    // MARK: - Temperature

    private func handle(_ reading: TemperatureMonitor.Reading) {
        lastReading = reading

        if reading.level != currentLevel {
            apply(level: reading.level)
        }

        if menuIsOpen {
            headerItem?.attributedTitle = cpuHeaderText()
            gpuHeaderItem?.attributedTitle = gpuHeaderText(reading)
            powerHeaderItem?.attributedTitle = powerHeaderText(reading)
        }
    }

    private func apply(level: HeatLevel) {
        currentLevel = level
        statusItem.button?.image = dotImages[level]
        statusItem.button?.setAccessibilityLabel(
            String(format: L("a11y.level", "Heat level: %@"), label(for: level)))
    }

    private func label(for level: HeatLevel) -> String {
        switch level {
        case .cool: return L("level.normal", "normal")
        case .warm: return L("level.elevated", "elevated")
        case .hot: return L("level.high", "high")
        }
    }

    // MARK: - Menu lifecycle

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true

        temperature.primePower()
        buildStructure()
        let fresh = lastReportAt.map { Date().timeIntervalSince($0) < 30 } ?? false
        apply(fresh ? lastReport : nil)

        // GPU counters are only needed while the list is visible.
        refreshGpuBaseline()
        requestReport()

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.requestReport()
        }
        RunLoop.main.add(timer, forMode: .common)
        liveRefreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = nil
    }

    private func requestReport() {
        guard !reportPending else { return }
        reportPending = true

        gpuQueue.async { [weak self] in
            guard let self else { return }
            let deltas = self.collectGpuSeconds()

            self.sampler.report(gpuSeconds: deltas) { [weak self] report in
                guard let self else { return }
                self.reportPending = false
                guard self.menuIsOpen else { return }

                if let report {
                    self.lastReport = report
                    self.lastReportAt = Date()
                }
                self.apply(report)
            }
        }
    }

    // MARK: - GPU time

    private func refreshGpuBaseline() {
        gpuQueue.async { [weak self] in
            guard let self else { return }
            self.gpuBaseline = Self.gpuTimeSnapshot()
        }
    }

    /// Per-process GPU seconds since the last baseline. Counters restart when a
    /// command queue is recycled, so a shrinking value is treated as zero.
    private func collectGpuSeconds() -> [pid_t: Double] {
        let current = Self.gpuTimeSnapshot()
        let previous = gpuBaseline
        gpuBaseline = current

        Self.debugLog("collect gpu pids=\(current.count) prev=\(previous.count)")
        var deltas: [pid_t: Double] = [:]
        for (pid, nanoseconds) in current {
            guard let before = previous[pid], nanoseconds > before else { continue }
            deltas[pid] = Double(nanoseconds - before) / 1e9
        }
        Self.debugLog("deltas=\(deltas.count) sum=\(deltas.values.reduce(0, +))")
        return deltas
    }

    private static func gpuTimeSnapshot() -> [pid_t: UInt64] {
        var pointer: UnsafeMutablePointer<proc_gpu_time_t>?
        let count = Int(gpu_time_snapshot(&pointer))
        defer { free(pointer) }
        guard count > 0, let entries = pointer else { return [:] }

        var values: [pid_t: UInt64] = [:]
        for index in 0..<count {
            values[entries[index].pid, default: 0] += entries[index].gpu_ns
        }
        return values
    }

    // MARK: - Rendering

    private func buildStructure() {
        menu.removeAllItems()

        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.attributedTitle = cpuHeaderText()
        header.isEnabled = true
        menu.addItem(header)
        headerItem = header

        let gpuHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        gpuHeader.attributedTitle = lastReading.map(gpuHeaderText) ??
            NSAttributedString(string: L("header.gpuPending", "GPU …"))
        gpuHeader.isEnabled = true
        gpuHeader.isHidden = !(lastReading?.hasGpu ?? true)
        menu.addItem(gpuHeader)
        gpuHeaderItem = gpuHeader

        let powerHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        powerHeader.attributedTitle = lastReading.map(powerHeaderText) ??
            NSAttributedString(string: L("header.powerPending", "System …"),
                               attributes: Self.headerStyle)
        powerHeader.isEnabled = true
        powerHeader.isHidden = !(lastReading?.hasPower ?? true)
        menu.addItem(powerHeader)
        powerHeaderItem = powerHeader

        menu.addItem(.separator())

        measuringItem = disabled(L("menu.measuring", "Measuring…"))
        menu.addItem(measuringItem!)
        idleItem = disabled(L("menu.idle", "Nothing drawing energy right now"))
        menu.addItem(idleItem!)

        gpuCaptionItem = disabledCaption(L("menu.gpuSection", "GPU heat"))
        menu.addItem(gpuCaptionItem!)

        gpuRowItems = (0..<3).map { _ in
            let item = NSMenuItem(title: "", action: #selector(activateApp(_:)), keyEquivalent: "")
            item.target = self
            item.image = Self.blankIcon
            menu.addItem(item)
            return item
        }

        gpuSectionSeparator = .separator()
        menu.addItem(gpuSectionSeparator!)

        energyCaptionItem = disabledCaption(L("menu.energySection", "Energy draw"))
        menu.addItem(energyCaptionItem!)

        rowItems = (0..<5).map { _ in
            let item = NSMenuItem(title: "", action: #selector(activateApp(_:)), keyEquivalent: "")
            item.target = self
            item.image = Self.blankIcon
            menu.addItem(item)
            return item
        }

        menu.addItem(.separator())

        let total = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        total.isEnabled = false
        menu.addItem(total)
        totalItem = total

        menu.addItem(.separator())
        menu.addItem(loginItem())
        menu.addItem(quitItem())
    }

    private static func debugLog(_ line: String) {
        let path = "/tmp/heatwatch.debug"
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    private func apply(_ report: EnergySampler.Report?) {
        Self.debugLog("apply gpuRows=\(report?.gpuUsages.count ?? -1) energyRows=\(report?.usages.count ?? -1) gpuLoad=\(lastReading?.gpuLoad ?? -99)")
        guard let report else {
            measuringItem?.isHidden = false
            idleItem?.isHidden = true
            hideRows()
            powerHeaderItem?.isHidden = !(lastReading?.hasPower ?? true)
            totalItem?.isHidden = true
            return
        }

        // The GPU list only earns its space while the GPU is actually busy.
        let gpuBusy = (lastReading?.gpuLoad ?? 0) >= 15 && !report.gpuUsages.isEmpty
        fill(gpuRowItems, with: gpuBusy ? report.gpuUsages : [])
        fill(rowItems, with: report.usages)

        powerHeaderItem?.isHidden = !(lastReading?.hasPower ?? false)
        gpuCaptionItem?.isHidden = !gpuBusy
        gpuSectionSeparator?.isHidden = !gpuBusy
        energyCaptionItem?.isHidden = !gpuBusy

        measuringItem?.isHidden = true
        idleItem?.isHidden = !report.usages.isEmpty || !report.gpuUsages.isEmpty

        totalItem?.isHidden = false
        totalItem?.attributedTitle = footerText(report.totalWatts)
    }

    private func fill(_ items: [NSMenuItem], with usages: [EnergySampler.Usage]) {
        for (index, item) in items.enumerated() {
            guard index < usages.count else {
                item.isHidden = true
                continue
            }
            let usage = usages[index]
            item.isHidden = false
            item.attributedTitle = usageTitle(name: usage.name, watts: usage.watts,
                                              gpuShare: usage.gpuShare)
            item.image = usage.icon ?? Self.blankIcon
            item.representedObject = usage.bundleIdentifier
            item.isEnabled = true
        }
    }

    private func hideRows() {
        (rowItems + gpuRowItems).forEach { $0.isHidden = true }
        gpuCaptionItem?.isHidden = true
        gpuSectionSeparator?.isHidden = true
        energyCaptionItem?.isHidden = true
    }

    private func disabledCaption(_ title: String) -> NSMenuItem {
        let item = disabled(title)
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static let headerStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    ]

    private func cpuHeaderText() -> NSAttributedString {
        guard let reading = lastReading else {
            return NSAttributedString(string: L("header.pending", "CPU …"),
                                      attributes: Self.headerStyle)
        }

        let value: String
        if reading.isFallback {
            value = String(format: L("header.load", "CPU %d %% load"), Int(reading.load.rounded()))
        } else {
            value = String(format: L("header.cpu", "CPU %@ °C · %d %%"),
                           Self.decimal(reading.value, digits: 1), Int(reading.load.rounded()))
        }
        return NSAttributedString(string: value, attributes: Self.headerStyle)
    }

    private func gpuHeaderText(_ reading: TemperatureMonitor.Reading) -> NSAttributedString {
        var parts: [String] = []
        if reading.gpuValue > 0 {
            parts.append(String(format: L("header.gpuTemp", "GPU %@ °C"),
                                Self.decimal(reading.gpuValue, digits: 1)))
        }
        if reading.gpuLoad >= 0 {
            parts.append(String(format: L("header.cpuLoad", "%d %%"), Int(reading.gpuLoad.rounded())))
        }

        let value = parts.isEmpty
            ? L("header.gpuPending", "GPU …")
            : parts.joined(separator: " · ")
        return NSAttributedString(string: value, attributes: Self.headerStyle)
    }

    /// Wall or battery draw of the whole machine. The per-app list below only
    /// sees user processes, so this is the number that matches a power meter.
    private func powerHeaderText(_ reading: TemperatureMonitor.Reading) -> NSAttributedString {
        let value = reading.hasPower
            ? String(format: L("header.power", "System %@ W"),
                     Self.decimal(reading.power, digits: 1))
            : L("header.powerPending", "System …")
        return NSAttributedString(string: value, attributes: Self.headerStyle)
    }

    private func usageTitle(name: String, watts: Double?, gpuShare: Double) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: 186, options: [:]),
            NSTextTab(textAlignment: .right, location: 232, options: [:])
        ]
        style.defaultTabInterval = 232
        style.lineBreakMode = .byTruncatingTail

        let font = NSFont.systemFont(ofSize: 13)
        let text = NSMutableAttributedString(string: Self.fit(name, font: font, width: 150), attributes: [
            .font: font
        ])
        text.append(NSAttributedString(string: "\t", attributes: [.paragraphStyle: style]))

        // GPU time is shown as a share of all GPU time; energy alone hides a
        // process that only spins the accelerator.
        let gpuText = gpuShare >= 1 ? String(format: L("menu.gpuShare", "%d %%"), Int(gpuShare.rounded())) : ""
        text.append(NSAttributedString(string: gpuText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: gpuShare >= 60 ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]))

        text.append(NSAttributedString(string: "\t", attributes: [.paragraphStyle: style]))
        let wattsText = watts.map { String(format: L("menu.watts", "%@ W"), Self.decimal($0, digits: 1)) }
            ?? L("menu.unknown", "—")
        text.append(NSAttributedString(string: wattsText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        text.addAttribute(.paragraphStyle, value: style,
                          range: NSRange(location: 0, length: text.length))
        return text
    }

    private func footerText(_ watts: Double) -> NSAttributedString {
        NSAttributedString(string: String(format: L("menu.appsTotal", "Apps: %@ W"),
                                          Self.decimal(watts, digits: 1)),
                           attributes: [
                            .font: NSFont.systemFont(ofSize: 11),
                            .foregroundColor: NSColor.secondaryLabelColor
                           ])
    }

    private func loginItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("menu.login", "Open at login"), action: #selector(toggleLogin), keyEquivalent: "")
        item.target = self
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item.isEnabled = true
        return item
    }

    private func quitItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("menu.quit", "Quit HeatWatch"), action: #selector(quit), keyEquivalent: "q")
        item.target = self
        item.isEnabled = true
        return item
    }

    // MARK: - Actions

    @objc private func activateApp(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("alert.login.title", "Could not change the login item")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        if menuIsOpen {
            buildStructure()
            apply(lastReport)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Clips a name to the fixed column, keeping the tail where Chrome-style
    /// helper suffixes live ("(Aperitif)" vs "(Aperitif Renderer)").
    private static func fit(_ text: String, font: NSFont, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attributes).width <= width { return text }

        let characters = Array(text)
        let tailCount = min(14, characters.count / 2)
        let suffix = String(characters.suffix(tailCount))
        var head = String(characters.dropLast(tailCount))

        while !head.isEmpty {
            head.removeLast()
            let candidate = head + "…" + suffix
            if (candidate as NSString).size(withAttributes: attributes).width <= width {
                return candidate
            }
        }
        return "…" + suffix
    }

    private static let blankIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        return image
    }()

    private static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.*f", digits, value).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Drawing

    private static func dotImage(for level: HeatLevel) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()

        let color: NSColor
        switch level {
        case .cool: color = .systemGreen
        case .warm: color = .systemYellow
        case .hot: color = .systemRed
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 8, height: 8)).fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

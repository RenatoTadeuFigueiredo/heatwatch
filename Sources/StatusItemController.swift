import AppKit
import Foundation
import ServiceManagement

final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let temperature = TemperatureMonitor()
    private let sampler = EnergySampler()

    private var dotImages: [HeatLevel: NSImage] = [:]
    private var liveRefreshTimer: Timer?
    private var backgroundBaselineTimer: Timer?
    private var headerItem: NSMenuItem?
    private var rowItems: [NSMenuItem] = []
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
            headerItem?.attributedTitle = headerText()
        }
    }

    private func apply(level: HeatLevel) {
        currentLevel = level
        statusItem.button?.image = dotImages[level]
        statusItem.button?.setAccessibilityLabel("Temperatura da CPU: \(label(for: level))")
    }

    private func label(for level: HeatLevel) -> String {
        switch level {
        case .cool: return "normal"
        case .warm: return "elevada"
        case .hot: return "alta"
        }
    }

    // MARK: - Menu lifecycle

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true

        buildStructure()
        let fresh = lastReportAt.map { Date().timeIntervalSince($0) < 30 } ?? false
        apply(fresh ? lastReport : nil)

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

        sampler.report { [weak self] report in
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

    // MARK: - Rendering

    private func buildStructure() {
        menu.removeAllItems()

        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.attributedTitle = headerText()
        header.isEnabled = true
        menu.addItem(header)
        headerItem = header

        menu.addItem(.separator())

        measuringItem = disabled("Medindo…")
        menu.addItem(measuringItem!)
        idleItem = disabled("Nada consumindo energia agora")
        menu.addItem(idleItem!)

        rowItems = (0..<5).map { _ in
            let item = NSMenuItem(title: "", action: #selector(activateApp(_:)), keyEquivalent: "")
            item.target = self
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

    private func apply(_ report: EnergySampler.Report?) {
        guard let report else {
            measuringItem?.isHidden = false
            idleItem?.isHidden = true
            rowItems.forEach { $0.isHidden = true }
            totalItem?.isHidden = true
            return
        }

        measuringItem?.isHidden = true
        idleItem?.isHidden = !report.usages.isEmpty

        for (index, item) in rowItems.enumerated() {
            guard index < report.usages.count else {
                item.isHidden = true
                continue
            }
            let usage = report.usages[index]
            item.isHidden = false
            item.attributedTitle = usageTitle(name: usage.name, share: usage.share)
            item.image = usage.icon
            item.representedObject = usage.bundleIdentifier
            item.isEnabled = true
        }

        totalItem?.isHidden = false
        totalItem?.attributedTitle = footerText(report.totalWatts)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func headerText() -> NSAttributedString {
        let value: String
        if let reading = lastReading {
            value = reading.isFallback
                ? "CPU \(Int(reading.load.rounded())) % de carga"
                : "CPU \(Self.decimal(reading.value, digits: 1)) °C · \(Int(reading.load.rounded())) %"
        } else {
            value = "CPU …"
        }

        return NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        ])
    }

    private func usageTitle(name: String, share: Double) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 220, options: [:])]
        style.defaultTabInterval = 220

        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13)
        ])
        text.append(NSAttributedString(string: "\t", attributes: [.paragraphStyle: style]))
        text.append(NSAttributedString(string: "\(Self.decimal(share, digits: 1)) %", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        text.addAttribute(.paragraphStyle, value: style,
                          range: NSRange(location: 0, length: text.length))
        return text
    }

    private func footerText(_ watts: Double) -> NSAttributedString {
        NSAttributedString(string: "Todos os processos: \(Self.decimal(watts, digits: 1)) W",
                           attributes: [
                            .font: NSFont.systemFont(ofSize: 11),
                            .foregroundColor: NSColor.secondaryLabelColor
                           ])
    }

    private func loginItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Abrir no login", action: #selector(toggleLogin), keyEquivalent: "")
        item.target = self
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item.isEnabled = true
        return item
    }

    private func quitItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Sair do HeatWatch", action: #selector(quit), keyEquivalent: "q")
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
            alert.messageText = "Não foi possível alterar o item de login"
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

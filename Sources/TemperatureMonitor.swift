import AppKit
import Foundation

enum HeatLevel: Int {
    case cool
    case warm
    case hot
}

/// Polls CPU die temperature on a background queue, with a CPU-load based
/// fallback for Macs that expose no die sensors.
final class TemperatureMonitor {

    struct Reading {
        let value: Double
        let load: Double
        let isFallback: Bool
        let level: HeatLevel
        let timestamp: Date
    }

    /// Thresholds follow each machine's own idle floor instead of a hardcoded
    /// figure, because an Air idles around 40 °C where an M3 Max idles near 60 °C.
    /// The floor drops instantly and drifts up slowly, so a warm room or a long
    /// render is absorbed without permanent false alarms.
    /// Absolute overrides: `defaults write local.renato.heatwatch warmCelsius 70`.
    private static let warmOffset = 8.0
    private static let hotOffset = 18.0
    private static var warmAbsolute: Double { threshold("warmCelsius") }
    private static var hotAbsolute: Double { threshold("hotCelsius") }
    private static var warmLoad: Double { threshold("warmLoadPercent", fallback: 45) }
    private static var hotLoad: Double { threshold("hotLoadPercent", fallback: 85) }
    private static let trendWindow: TimeInterval = 60
    private static let trendRise = 2.0

    private static func threshold(_ key: String, fallback: Double = 0) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : fallback
    }

    private let queue = DispatchQueue(label: "heatwatch.temperature", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var sensorRefreshTimer: DispatchSourceTimer?
    private var history: [Reading] = []
    private var floor: Double?
    private var sensorCount = 0
    private var consecutiveFailures = 0
    private var stopped = false

    var onUpdate: ((Reading) -> Void)?

    func start() {
        sensorCount = ProcessInfo.processInfo.environment["HEATWATCH_FORCE_FALLBACK"] == "1"
            ? 0
            : Int(hw_temp_init())
        if sensorCount == 0 {
            NSLog("HeatWatch: no die sensors, falling back to CPU load")
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.schedulePolling()
            self.scheduleSensorRefresh()
            self.read()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.pollTimer?.cancel()
            self.sensorRefreshTimer?.cancel()
            hw_temp_close()
        }
    }

    private func schedulePolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in self?.read() }
        timer.resume()
        pollTimer = timer
    }

    private func scheduleSensorRefresh() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(30))
        timer.setEventHandler {
            hw_temp_refresh_sensors()
            self.sensorCount = Int(hw_temp_sensor_count())
        }
        timer.resume()
        sensorRefreshTimer = timer
    }

    private func read() {
        guard !stopped else { return }

        let isFallback = sensorCount == 0
        let load = hw_cpu_load()
        let value: Double

        if isFallback {
            guard load >= 0 else { return }
            value = min(max(45.0 + load * 0.45, 40.0), 100.0)
        } else {
            value = hw_temp_read()
            guard value > 0 else {
                consecutiveFailures += 1
                if consecutiveFailures > 3 {
                    // Sensors can disappear across sleep or chip hot-plug events.
                    hw_temp_refresh_sensors()
                    sensorCount = Int(hw_temp_sensor_count())
                    consecutiveFailures = 0
                }
                return
            }
            consecutiveFailures = 0
        }

        let baseline = updateFloor(value)
        let reading = Reading(value: value, load: max(load, 0), isFallback: isFallback,
                              level: level(temperature: value, baseline: baseline, load: load),
                              timestamp: Date())

        history.append(reading)
        history.removeAll { reading.timestamp.timeIntervalSince($0.timestamp) > TemperatureMonitor.trendWindow }

        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(reading)
        }
    }

    /// Tracks the idle floor: instant on the way down, 2 % of the gap per tick upwards.
    private func updateFloor(_ value: Double) -> Double {
        guard let current = floor else {
            floor = value
            return value
        }
        let next = value <= current ? value : current + (value - current) * 0.02
        let clamped = min(max(next, 30), 80)
        floor = clamped
        return clamped
    }

    private func level(temperature: Double, baseline: Double, load: Double) -> HeatLevel {
        var result = level(forTemperature: temperature, baseline: baseline)
        let loadLevel = level(forLoad: load)
        if loadLevel.rawValue > result.rawValue {
            result = loadLevel
        }

        // A fast climb matters even while the absolute value is still low.
        guard result != .hot else { return .hot }
        guard let oldest = history.first,
              temperature - oldest.value >= TemperatureMonitor.trendRise else { return result }
        return .warm
    }

    private func level(forTemperature value: Double, baseline: Double) -> HeatLevel {
        let hot = TemperatureMonitor.hotAbsolute > 0
            ? TemperatureMonitor.hotAbsolute
            : baseline + TemperatureMonitor.hotOffset
        let warm = TemperatureMonitor.warmAbsolute > 0
            ? TemperatureMonitor.warmAbsolute
            : baseline + TemperatureMonitor.warmOffset

        if value >= hot { return .hot }
        if value >= warm { return .warm }
        return .cool
    }

    private func level(forLoad load: Double) -> HeatLevel {
        if load >= TemperatureMonitor.hotLoad { return .hot }
        if load >= TemperatureMonitor.warmLoad { return .warm }
        return .cool
    }
}

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

    /// Calibrated on an M3 Max: idle sits near 60-63 °C, 14 busy cores sustain 66-68 °C.
    /// The load term keeps the indicator useful when the fan curve hides a heavy workload.
    /// Both limits are overridable with `defaults write local.renato.heatwatch warmCelsius 70`.
    private static var warmThreshold: Double { threshold("warmCelsius", fallback: 66) }
    private static var hotThreshold: Double { threshold("hotCelsius", fallback: 74) }
    private static var warmLoad: Double { threshold("warmLoadPercent", fallback: 45) }
    private static var hotLoad: Double { threshold("hotLoadPercent", fallback: 85) }
    private static let trendWindow: TimeInterval = 60
    private static let trendRise = 2.0

    private static func threshold(_ key: String, fallback: Double) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : fallback
    }

    private let queue = DispatchQueue(label: "heatwatch.temperature", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var sensorRefreshTimer: DispatchSourceTimer?
    private var history: [Reading] = []
    private var sensorCount = 0
    private var consecutiveFailures = 0
    private var stopped = false

    var onUpdate: ((Reading) -> Void)?

    func start() {
        sensorCount = Int(hw_temp_init())
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

        let reading = Reading(value: value, load: max(load, 0), isFallback: isFallback,
                              level: level(temperature: value, load: load), timestamp: Date())

        history.append(reading)
        history.removeAll { reading.timestamp.timeIntervalSince($0.timestamp) > TemperatureMonitor.trendWindow }

        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(reading)
        }
    }

    private func level(temperature: Double, load: Double) -> HeatLevel {
        var result = level(forTemperature: temperature)
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

    private func level(forTemperature value: Double) -> HeatLevel {
        if value >= TemperatureMonitor.hotThreshold { return .hot }
        if value >= TemperatureMonitor.warmThreshold { return .warm }
        return .cool
    }

    private func level(forLoad load: Double) -> HeatLevel {
        if load >= TemperatureMonitor.hotLoad { return .hot }
        if load >= TemperatureMonitor.warmLoad { return .warm }
        return .cool
    }
}

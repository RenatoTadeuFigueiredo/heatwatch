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
        let gpuValue: Double
        let gpuLoad: Double
        let power: Double
        let isFallback: Bool
        let level: HeatLevel
        let timestamp: Date

        var hasGpu: Bool { gpuValue > 0 || gpuLoad >= 0 }
        var hasPower: Bool { power > 0 }
    }

    /// Thresholds follow each machine's own idle floor instead of a hardcoded
    /// figure, because an Air idles around 40 °C where an M3 Max idles near 60 °C.
    /// The floor drops instantly and drifts up slowly, so a warm room or a long
    /// render is absorbed without permanent false alarms.
    /// Absolute overrides: `defaults write io.github.renatotadeufigueiredo.heatwatch warmCelsius 70`.
    private static let warmOffset = 8.0
    private static let hotOffset = 18.0
    private static var warmAbsolute: Double { threshold("warmCelsius") }
    private static var hotAbsolute: Double { threshold("hotCelsius") }
    private static var warmGpuAbsolute: Double { threshold("warmGpuCelsius") }
    private static var hotGpuAbsolute: Double { threshold("hotGpuCelsius") }
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
    private var gpuFloor: Double?
    private var sensorCount = 0
    private var gpuSensorCount = 0
    private var consecutiveFailures = 0
    private var stopped = false
    private var lastPowerAt: TimeInterval = 0
    private var power: Double = -1

    var onUpdate: ((Reading) -> Void)?

    func start() {
        sensorCount = ProcessInfo.processInfo.environment["HEATWATCH_FORCE_FALLBACK"] == "1"
            ? 0
            : Int(hw_temp_init())
        gpuSensorCount = sensorCount == 0 ? 0 : Int(hw_temp_gpu_sensor_count())
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

    /// Forces the next tick to re-read the battery, e.g. when the menu opens.
    func primePower() {
        queue.async { [weak self] in self?.lastPowerAt = 0 }
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
        timer.schedule(deadline: .now() + 10, repeating: 5, leeway: .seconds(2))
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
            self.gpuSensorCount = Int(hw_temp_gpu_sensor_count())
        }
        timer.resume()
        sensorRefreshTimer = timer
    }

    private func read() {
        guard !stopped else { return }

        let isFallback = sensorCount == 0
        let load = hw_cpu_load()
        let gpuLoad = hw_gpu_utilization()
        // Battery telemetry is the most expensive read of the tick and the
        // value moves slowly, so it refreshes on its own 15 s cadence.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPowerAt >= 15 {
            lastPowerAt = now
            power = hw_system_power()
        }
        let value: Double

        if isFallback {
            guard load >= 0 else { return }
            value = min(max(45.0 + load * 0.45, 40.0), 100.0)
        } else {
            value = hw_temp_read_cpu()
            guard value > 0 else {
                consecutiveFailures += 1
                if consecutiveFailures > 3 {
                    // Sensors can disappear across sleep or chip hot-plug events.
                    hw_temp_refresh_sensors()
                    sensorCount = Int(hw_temp_sensor_count())
                    gpuSensorCount = Int(hw_temp_gpu_sensor_count())
                    consecutiveFailures = 0
                }
                return
            }
            consecutiveFailures = 0
        }

        // GPU sensors come and go with the accelerator; a missing sensor is not
        // an error, it only means the GPU contributes through utilization alone.
        let gpuValue = gpuSensorCount > 0 ? hw_temp_read_gpu() : -1.0
        if gpuValue > 0 {
            // Starting the app mid-fry must not adopt the hot value as the floor.
            gpuFloor = gpuFloor.map { trackFloor(gpuValue, floor: $0) } ?? min(gpuValue, 60)
        }

        let baseline = updateFloor(value)
        let reading = Reading(value: value, load: max(load, 0),
                              gpuValue: gpuValue, gpuLoad: gpuLoad, power: power,
                              isFallback: isFallback,
                              level: level(temperature: value, baseline: baseline, load: load,
                                           gpuTemperature: gpuValue, gpuBaseline: gpuFloor,
                                           gpuLoad: gpuLoad),
                              timestamp: Date())


        history.append(reading)
        history.removeAll { reading.timestamp.timeIntervalSince($0.timestamp) > TemperatureMonitor.trendWindow }

        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(reading)
        }
    }

    /// Tracks an idle floor: instant on the way down, 2 % of the gap per tick upwards.
    private func updateFloor(_ value: Double) -> Double {
        let next = trackFloor(value, floor: floor)
        floor = next
        return next
    }

    private func trackFloor(_ value: Double, floor current: Double?) -> Double {
        guard let current else { return value }
        let next = value <= current ? value : current + (value - current) * 0.02
        return min(max(next, 30), 80)
    }

    private func level(temperature: Double, baseline: Double, load: Double,
                       gpuTemperature: Double, gpuBaseline: Double?,
                       gpuLoad: Double) -> HeatLevel {
        var result = level(forTemperature: temperature, baseline: baseline,
                           hotOverride: TemperatureMonitor.hotAbsolute,
                           warmOverride: TemperatureMonitor.warmAbsolute)

        // A busy GPU heats the shared die, so it can escalate the dot on its own.
        if let gpuBaseline, gpuTemperature > 0 {
            let gpuLevel = level(forTemperature: gpuTemperature, baseline: gpuBaseline,
                                 hotOverride: TemperatureMonitor.hotGpuAbsolute,
                                 warmOverride: TemperatureMonitor.warmGpuAbsolute)
            if gpuLevel.rawValue > result.rawValue { result = gpuLevel }
        }

        let loadLevel = level(forLoad: load)
        if loadLevel.rawValue > result.rawValue { result = loadLevel }

        if gpuLoad >= 0 {
            let gpuLoadLevel = level(forLoad: gpuLoad)
            if gpuLoadLevel.rawValue > result.rawValue { result = gpuLoadLevel }
        }

        // A fast climb matters even while the absolute value is still low.
        guard result != .hot else { return .hot }
        guard let oldest = history.first,
              temperature - oldest.value >= TemperatureMonitor.trendRise else { return result }
        return .warm
    }

    private func level(forTemperature value: Double, baseline: Double,
                       hotOverride: Double, warmOverride: Double) -> HeatLevel {
        let hot = hotOverride > 0 ? hotOverride : baseline + TemperatureMonitor.hotOffset
        let warm = warmOverride > 0 ? warmOverride : baseline + TemperatureMonitor.warmOffset

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

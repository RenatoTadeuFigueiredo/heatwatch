import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = StatusItemController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}

/// Headless mode used for verification: prints one reading and one ranking.
private func runProbe() {
    let sensors = ProcessInfo.processInfo.environment["HEATWATCH_FORCE_FALLBACK"] == "1"
        ? 0
        : Int(hw_temp_init())
    defer { hw_temp_close() }

    let sampler = EnergySampler()
    sampler.refreshBaseline()

    func gpuSnapshot() -> [pid_t: UInt64] {
        var pointer: UnsafeMutablePointer<proc_gpu_time_t>?
        let count = Int(gpu_time_snapshot(&pointer))
        defer { free(pointer) }
        guard count > 0, let entries = pointer else { return [:] }
        var values: [pid_t: UInt64] = [:]
        for index in 0..<count { values[entries[index].pid, default: 0] += entries[index].gpu_ns }
        return values
    }

    let gpuBefore = gpuSnapshot()
    Thread.sleep(forTimeInterval: 1.5)
    let gpuAfter = gpuSnapshot()
    var gpuSeconds: [pid_t: Double] = [:]
    for (pid, nanoseconds) in gpuAfter {
        guard let before = gpuBefore[pid], nanoseconds > before else { continue }
        gpuSeconds[pid] = Double(nanoseconds - before) / 1e9
    }

    var finished = false
    sampler.report(gpuSeconds: gpuSeconds) { report in
        defer { finished = true }

        let temperature = sensors > 0 ? hw_temp_read_cpu() : -1
        let gpuTemperature = sensors > 0 ? hw_temp_read_gpu() : -1
        print(String(format: "sensors=%d temp=%.1f°C gpu=%.1f°C gpuLoad=%.0f%% load=%.0f%% system=%.1fW",
                     sensors, temperature, gpuTemperature, hw_gpu_utilization(), hw_cpu_load(),
                     hw_system_power()))
        guard let report else {
            print("no report")
            return
        }
        print(String(format: "total=%.2fW", report.totalWatts))
        for usage in report.usages {
            print(String(format: "%5.1f%% %7.3fW %5.1f%%gpu  %@",
                         usage.share, usage.watts ?? -1, usage.gpuShare, usage.name))
        }
    }

    let deadline = Date().addingTimeInterval(5)
    while !finished && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}

/// Streams monitor readings, so the heat level can be checked without the UI.
private func runWatch(seconds: TimeInterval) {
    let monitor = TemperatureMonitor()
    monitor.onUpdate = { reading in
        print(String(format: "level=%d temp=%.1f gpu=%.1f gpuLoad=%.0f load=%.0f power=%.1f",
                     reading.level.rawValue, reading.value, reading.gpuValue,
                     reading.gpuLoad, reading.load, reading.power))
    }
    monitor.start()

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    monitor.stop()
}

if CommandLine.arguments.contains("--watch") {
    let index = CommandLine.arguments.firstIndex(of: "--watch") ?? 0
    let seconds = CommandLine.arguments.count > index + 1
        ? Double(CommandLine.arguments[index + 1]) ?? 20
        : 20
    runWatch(seconds: seconds)
    exit(0)
}

if CommandLine.arguments.contains("--probe") {
    runProbe()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()

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

/// Headless mode used for verification: prints one temperature reading and one ranking.
private func runProbe() {
    let sensors = Int(hw_temp_init())
    defer { hw_temp_close() }

    let sampler = EnergySampler()
    sampler.refreshBaseline()
    Thread.sleep(forTimeInterval: 1.5)

    var finished = false
    sampler.report { report in
        defer { finished = true }

        let temperature = hw_temp_read()
        print(String(format: "sensors=%d temp=%.1f°C", sensors, temperature))
        guard let report else {
            print("no report")
            return
        }
        print(String(format: "total=%.2fW", report.totalWatts))
        for usage in report.usages {
            print(String(format: "%5.1f%% %7.3fW  %@", usage.share, usage.watts, usage.name))
        }
    }

    let deadline = Date().addingTimeInterval(5)
    while !finished && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}

if CommandLine.arguments.contains("--probe") {
    runProbe()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()

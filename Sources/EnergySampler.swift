import AppKit
import Foundation

/// Snapshots per-process energy counters (`ri_energy_nj`) and turns two
/// snapshots into an app-level ranking. No privileged helper required:
/// root-owned processes are simply invisible.
final class EnergySampler {

    struct Sample {
        let timestamp: TimeInterval
        let energies: [pid_t: UInt64]
    }

    struct Usage {
        let name: String
        let icon: NSImage?
        let bundleIdentifier: String?
        let share: Double
        let watts: Double
    }

    struct Report {
        let usages: [Usage]
        let totalWatts: Double
    }

    private struct Resolved {
        let key: String
        let name: String
        let bundle: String?
        let icon: NSImage?
        let stamp: TimeInterval
    }

    private let queue = DispatchQueue(label: "heatwatch.energy", qos: .utility)
    private var resolved: [pid_t: Resolved] = [:]
    private(set) var baseline: Sample?

    func sample() -> Sample? {
        var pointer: UnsafeMutablePointer<proc_energy_t>?
        let count = Int(proc_energy_snapshot(&pointer))
        defer { free(pointer) }
        guard count > 0, let entries = pointer else { return nil }

        var energies: [pid_t: UInt64] = [:]
        energies.reserveCapacity(count)
        for index in 0..<count {
            energies[entries[index].pid] = entries[index].energy_nj
        }
        return Sample(timestamp: ProcessInfo.processInfo.systemUptime, energies: energies)
    }

    /// Refreshes the background baseline; cheap enough to run every 15 s.
    func refreshBaseline(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.baseline = self.sample()
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    /// Ranks applications by energy delta between the baseline and a fresh sample.
    /// Must be called on the main queue because app lookup uses AppKit.
    func report(completion: @escaping (Report?) -> Void) {
        queue.async { [weak self] in
            guard let self, let previous = self.baseline else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            guard let current = self.sample() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.baseline = current

            let elapsed = max(current.timestamp - previous.timestamp, 0.5)
            var deltas: [(pid: pid_t, energy: UInt64)] = []
            deltas.reserveCapacity(current.energies.count)

            for (pid, energy) in current.energies {
                guard let before = previous.energies[pid], energy > before else { continue }
                let delta = energy - before
                if delta > 0 { deltas.append((pid, delta)) }
            }

            let total = deltas.reduce(UInt64(0)) { $0 &+ $1.energy }
            guard total > 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Resolving every pid is wasteful; keep anything above 0.2 % of the total.
            deltas.sort { $0.energy > $1.energy }
            let floor = Double(total) * 0.002
            let candidates = deltas.prefix { Double($0.energy) >= floor }.prefix(40)

            DispatchQueue.main.async {
                completion(self.build(candidates: Array(candidates), total: total, elapsed: elapsed))
            }
        }
    }

    private func build(candidates: [(pid: pid_t, energy: UInt64)],
                       total: UInt64,
                       elapsed: TimeInterval) -> Report {
        var grouped: [String: (name: String, icon: NSImage?, bundle: String?, energy: UInt64)] = [:]
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let now = ProcessInfo.processInfo.systemUptime

        for candidate in candidates where candidate.pid != ownPid {
            guard let info = resolve(candidate.pid, now: now) else { continue }

            if var existing = grouped[info.key] {
                existing.energy &+= candidate.energy
                grouped[info.key] = existing
                continue
            }
            grouped[info.key] = (info.name, info.icon, info.bundle, candidate.energy)
        }

        prune(now: now)

        let usages = grouped.values
            .sorted { $0.energy > $1.energy }
            .prefix(5)
            .map { entry in
                Usage(name: entry.name,
                      icon: entry.icon,
                      bundleIdentifier: entry.bundle,
                      share: Double(entry.energy) / Double(total) * 100.0,
                      watts: Double(entry.energy) / elapsed / 1e9)
            }

        let totalWatts = Double(total) / elapsed / 1e9
        return Report(usages: Array(usages), totalWatts: totalWatts)
    }

    /// App metadata is stable for minutes, so it is cached to keep refreshes cheap.
    private func resolve(_ pid: pid_t, now: TimeInterval) -> Resolved? {
        if let cached = resolved[pid], now - cached.stamp < 120 {
            return cached
        }

        let app = NSRunningApplication(processIdentifier: pid)
        let path = app?.bundleURL?.path ?? executablePath(for: pid)
        let name = app?.localizedName ?? path.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
        let key = app?.bundleIdentifier ?? path ?? "pid:\(pid)"

        var icon: NSImage?
        if let appIcon = app?.icon {
            let small = appIcon.copy() as? NSImage
            small?.size = NSSize(width: 16, height: 16)
            icon = small
        }

        let info = Resolved(key: key, name: name, bundle: app?.bundleIdentifier,
                            icon: icon, stamp: now)
        resolved[pid] = info
        return info
    }

    private func prune(now: TimeInterval) {
        guard resolved.count > 400 else { return }
        resolved = resolved.filter { now - $0.value.stamp < 300 }
    }

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pid_path(pid, &buffer, buffer.count) == 0 else { return nil }
        return String(cString: buffer)
    }
}

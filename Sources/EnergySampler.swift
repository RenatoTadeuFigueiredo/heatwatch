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
        let gpuShare: Double
        /// Nil for processes whose energy counter is not readable (root-owned).
        let watts: Double?
    }

    struct Report {
        /// Processes with the largest GPU time; disjoint from `usages`.
        let gpuUsages: [Usage]
        let usages: [Usage]
        let totalWatts: Double
    }

    /// Below this many GPU seconds in a window a process is not worth a row.
    private static let gpuSecondsFloor = 0.1

    private struct Resolved {
        let key: String
        let name: String
        let bundle: String?
        let icon: NSImage?
        let stamp: TimeInterval
    }

    private struct Group {
        let name: String
        let icon: NSImage?
        let bundle: String?
        var energy: UInt64
        var energyKnown: Bool
        var gpuSeconds: Double
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

    /// Ranks applications by the energy and GPU time they accumulated between
    /// the baseline and a fresh sample. Both signals are normalized to a share
    /// and summed, so a process that only heats the GPU still shows up.
    /// Must be called on the main queue because app lookup uses AppKit.
    func report(gpuSeconds: [pid_t: Double], completion: @escaping (Report?) -> Void) {
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
            var energyDeltas: [pid_t: UInt64] = [:]
            energyDeltas.reserveCapacity(current.energies.count)

            for (pid, energy) in current.energies {
                guard let before = previous.energies[pid], energy > before else { continue }
                let delta = energy - before
                if delta > 0 { energyDeltas[pid] = delta }
            }

            let total = energyDeltas.values.reduce(UInt64(0)) { $0 &+ $1 }
            let gpuTotal = gpuSeconds.values.reduce(0, +)
            guard total > 0 || gpuTotal > 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Resolving every pid is wasteful; keep anything above 0.2 % of the
            // total, plus every process that put real time on the GPU.
            let ranked = energyDeltas.sorted { $0.value > $1.value }
            let floor = Double(total) * 0.002
            var candidates = Set(ranked.prefix { Double($0.value) >= floor }.prefix(40).map(\.key))
            candidates.formUnion(gpuSeconds.filter { $0.value >= 0.05 }.keys)

            DispatchQueue.main.async {
                completion(self.build(candidates: Array(candidates), energies: energyDeltas,
                                      total: total, gpuTotal: gpuTotal,
                                      gpuSeconds: gpuSeconds, elapsed: elapsed))
            }
        }
    }

    private func build(candidates: [pid_t],
                       energies: [pid_t: UInt64],
                       total: UInt64,
                       gpuTotal: Double,
                       gpuSeconds: [pid_t: Double],
                       elapsed: TimeInterval) -> Report {
        var grouped: [String: Group] = [:]
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let now = ProcessInfo.processInfo.systemUptime

        for pid in candidates where pid != ownPid {
            let energy = energies[pid]
            let gpu = gpuSeconds[pid] ?? 0
            guard (energy ?? 0) > 0 || gpu > 0, let info = resolve(pid, now: now) else { continue }

            if var existing = grouped[info.key] {
                existing.energy &+= energy ?? 0
                existing.energyKnown = existing.energyKnown || energy != nil
                existing.gpuSeconds += gpu
                grouped[info.key] = existing
                continue
            }
            grouped[info.key] = Group(name: info.name, icon: info.icon, bundle: info.bundle,
                                      energy: energy ?? 0, energyKnown: energy != nil,
                                      gpuSeconds: gpu)
        }

        prune(now: now)

        func usage(_ group: Group) -> Usage {
            Usage(name: group.name,
                  icon: group.icon,
                  bundleIdentifier: group.bundle,
                  share: total > 0 ? Double(group.energy) / Double(total) * 100.0 : 0,
                  gpuShare: gpuTotal > 0 ? group.gpuSeconds / gpuTotal * 100.0 : 0,
                  watts: group.energyKnown ? Double(group.energy) / elapsed / 1e9 : nil)
        }

        // GPU time gets its own list: energy alone hides the process that is
        // actually driving the die. The energy list then skips those rows.
        let gpuTop = grouped
            .filter { $0.value.gpuSeconds >= Self.gpuSecondsFloor }
            .sorted { $0.value.gpuSeconds > $1.value.gpuSeconds }
            .prefix(3)
        let gpuKeys = Set(gpuTop.map(\.key))

        let energyTop = grouped
            .filter { !gpuKeys.contains($0.key) && $0.value.energy > 0 }
            .sorted { $0.value.energy > $1.value.energy }
            .prefix(5)

        let totalWatts = Double(total) / elapsed / 1e9
        return Report(gpuUsages: gpuTop.map { usage($0.value) },
                      usages: energyTop.map { usage($0.value) },
                      totalWatts: totalWatts)
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

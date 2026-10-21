<p align="center">
  <img src="assets/header.svg" alt="HeatWatch — a heat indicator that lives in the menu bar" width="100%">
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-1c1c1e?logo=apple&logoColor=white">
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-1c1c1e">
  <img alt="AppKit" src="https://img.shields.io/badge/AppKit-native-1c1c1e?logo=swift&logoColor=white">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-30d158">
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-1c1c1e">
</p>

HeatWatch puts a colored dot next to your clock. Green while the Mac is calm,
yellow when it starts working, red when it is cooking — and a click shows the five
apps responsible for most of the heat right now, CPU and GPU alike.

It is a 736 KB native AppKit app. No Electron, no daemon, no network, no root
helper, no analytics. While the menu is closed it runs at **0.0 % CPU** with a
~22 MB footprint.

> **The released build is ad-hoc signed, not notarized** (no Apple Developer
> account behind this project). macOS will block the first launch until you clear
> the quarantine flag — one command, see [Install](#install).

## Features

- Menu bar dot driven by CPU and GPU die temperature plus both load figures, with
  a bump when the temperature climbs fast
- The three processes eating the GPU, in their own section whenever the GPU is
  busy, above the five biggest energy draws (helpers roll into their app)
- Per-machine thresholds: bands follow the machine's own idle floor, so an Air and
  a MacBook Pro both get a meaningful scale
- Optional launch at login
- English and Portuguese (pt-BR) UI, following the system language
- Nothing leaves the machine

## Install

### Download

Grab the latest `HeatWatch-<version>.dmg` (or `.zip`) from
[Releases](../../releases), drag the app to `/Applications`, then clear the
quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/HeatWatch.app
```

Open the app normally. On macOS 14 and older the right-click → **Open** path also
works; on macOS 15+ use **System Settings → Privacy & Security → Open Anyway** if
you prefer the GUI.

Each release ships `SHA256SUMS`; verify with `shasum -a 256 -c SHA256SUMS` before
installing if you care about that.

### Build from source

Requires the Xcode command line tools (Swift 5.7+). No other dependency.

```sh
git clone https://github.com/RenatoTadeuFigueiredo/heatwatch.git
cd heatwatch
./install.sh          # builds universal, installs to /Applications, launches
```

`./build.sh` alone leaves the bundle in `build/`, and `./dist.sh` produces the
ZIP/DMG pair with checksums.

## Usage

Click the dot:

| Row | Meaning |
|---|---|
| `CPU 61.4 °C · 12 %` | Current CPU die temperature and total CPU load |
| `GPU 58.2 °C · 96 %` | Hottest GPU cluster and GPU duty cycle |
| `GPU heat` | Appears while the GPU is busy; the three processes with the most GPU time |
| `Energy draw` | Five processes with the largest energy draw |
| App rows | Both figures over the last ~2 s: share of GPU time, then watts; names are clipped in the middle, `—` means the process hides its energy counter (root-owned) |
| `All processes: 7.1 W` | Total energy attributable to user processes |
| `Open at login` | Registers the app as a login item |

Quit from the menu. Uninstall by deleting `/Applications/HeatWatch.app`.

## How it works

| Signal | Source | Cost |
|---|---|---|
| CPU temperature | Private IOHID sensor API, `PMU tdie*` die sensors, five sampled per tick | ~2 ms / 5 s |
| GPU temperature | Same API, hottest `PMU tdev*` cluster | ~3 ms / 5 s |
| GPU duty | `Device Utilization %` from the accelerator's `PerformanceStatistics` | ~1 ms / 5 s |
| Per-app energy | `proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj`, diffed between snapshots and grouped by bundle | ~6 ms / 15 s closed, 2 s while open |
| Per-app GPU time | `AppUsage.accumulatedGPUTime` on each `AGXDeviceUserClient`, diffed the same way | only while the menu is open |

The dot color is `max(CPU band, GPU band, CPU load band, GPU load band)`, plus one
level when the CPU die rises 2 °C within a minute. Load is part of it because a well
cooled Mac hides heavy work behind a flat temperature curve, and because a process
can pin the GPU while the CPU stays quiet.

GPU time and energy are ranked separately, because watts alone bury a Metal or ML
job that spins the accelerator at 0.1 W. The GPU section hides itself when the GPU
is idle, and rows never repeat across the two lists. Thresholds track each die's own
idle floor — dropping instantly, drifting up 2 % per tick — with fixed offsets of
+8 °C and +18 °C. Absolute overrides win:

```sh
defaults write io.github.renatotadeufigueiredo.heatwatch warmCelsius 70
defaults write io.github.renatotadeufigueiredo.heatwatch hotCelsius 80
defaults write io.github.renatotadeufigueiredo.heatwatch warmGpuCelsius 65
defaults write io.github.renatotadeufigueiredo.heatwatch hotGpuCelsius 78
defaults write io.github.renatotadeufigueiredo.heatwatch warmLoadPercent 60
defaults write io.github.renatotadeufigueiredo.heatwatch hotLoadPercent 90
```

## Footprint

Measured on an M3 Max, macOS 27:

| State | CPU | Physical footprint |
|---|---|---|
| Idle, menu closed | 0.0–0.2 % | ~22 MB |
| Menu open (2 s refresh) | ~0.6 % | ~23 MB |

One temperature and GPU read every 5 s and one process scan every 15 s is the
entire background cost; GPU time counters are only touched while the menu is open.
Icons and menu rows are reused instead of rebuilt.

## Compatibility

- macOS 13 or newer, Apple Silicon and Intel.
- Apple Silicon exposes `PMU tdie` and `PMU tdev` sensors. On Macs without them
  (Intel) the app falls back to CPU and GPU load and the header shows percentages.
- The temperature API is private. A macOS update can break it; the load fallback
  keeps the indicator alive meanwhile.

## Limitations

- Root-owned processes hide their energy counter, so rows like `WindowServer` show
  `—` upstream of a wattage; their GPU time is still measured, and kernel threads
  (no GPU queue) stay out of the ranking.
- Die temperature is not "how hot it feels"; the dots are a trend signal, not a
  thermal specification.
- GPU temperature needs `PMU tdev` sensors; without them the GPU still counts
  through its duty cycle.
- No auto-update. Re-download to upgrade.
- Not notarized, and the private API rules out the App Store without a privileged
  helper running `powermetrics`.

## Privacy

No network access, no telemetry, no crash reporting, no TCC prompts. The only
state is user defaults for thresholds. Energy and temperature readings never leave
the machine.

## Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
The code is a handful of small Swift/C files under `Sources/`; `--probe` prints one
reading and one ranking without a UI, which is also what CI smokes, and `--watch`
streams the computed heat level.

## License

[MIT](LICENSE).

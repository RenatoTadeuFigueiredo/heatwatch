# HeatWatch

Menu bar heat indicator for macOS. A colored dot next to the clock turns from
green to yellow to red as the machine heats up, and the dropdown lists the five
apps currently responsible for most of the CPU/GPU energy draw.

Native AppKit, no Electron, no network, no root helper.

## Measured footprint on an M3 Max (macOS 27)

| State | CPU | Physical footprint |
|---|---|---|
| Idle, menu closed | 0.0-0.2 % | ~22 MB |
| Menu open (2 s refresh) | ~0.6 % | ~23 MB |
| Bundle on disk | — | 220 KB |

The idle cost is one temperature read every 10 s (~3 ms) plus one process scan
every 15 s (~6 ms). Process scanning stops completely while the menu is closed,
apart from that baseline sample.

## How it works

- **Temperature** — the private IOHID sensor API (`IOHIDEventSystemClient`
  matched on usage page `0xff00`, usage `5`). CPU die sensors are named
  `PMU tdieN`; five of them are sampled per tick. No root, no `powermetrics`.
- **Energy per app** — `proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj`, the same
  counter Activity Monitor builds its energy figure from. Two snapshots are
  diffed and grouped by bundle, so helper processes roll up into their app.
- **Color** — `max(temperature band, load band)`, with an extra bump when the
  die temperature climbs 2 °C within a minute. Load is included because a well
  cooled Mac hides heavy work behind a flat temperature curve.

## Build and install

```sh
./install.sh          # builds, copies to /Applications, launches
```

`./build.sh` alone produces `build/HeatWatch.app`. The bundle is ad-hoc signed;
Gatekeeper is fine with a local build.

Enable "Abrir no login" from the menu to start it at login (uses
`SMAppService`).

Uninstall: quit from the menu, then `rm -rf /Applications/HeatWatch.app`.

## Configuration

```sh
defaults write local.renato.heatwatch warmCelsius 70
defaults write local.renato.heatwatch hotCelsius 80
defaults write local.renato.heatwatch warmLoadPercent 60
defaults write local.renato.heatwatch hotLoadPercent 90
```

Defaults are calibrated for this machine (idle 60-63 °C, 14 busy cores sustain
66-68 °C): 66 °C / 74 °C and 45 % / 85 % load.

## Verification

```sh
build/HeatWatch.app/Contents/MacOS/HeatWatch --probe
```

Prints one temperature reading and one ranking without opening a UI.

## Limitations

- Processes owned by root are not readable without a privileged helper, so
  `WindowServer` and kernel threads never appear in the ranking. User apps,
  which is what the list is for, do.
- `PMU tdie` sensors exist on Apple Silicon. On Macs without them the app falls
  back to CPU load and the header shows a percentage instead of °C.
- The temperature is a die sensor average, not a "how hot does it feel" number.

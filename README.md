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
| Bundle on disk | — | 728 KB (universal) |

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
- **Per-machine thresholds** — bands follow the machine's own idle floor
  (dropping instantly, drifting up 2 %/tick), because an Air idles near 40 °C
  where an M3 Max idles near 60 °C. Fixed offsets: +8 °C warm, +18 °C hot.

## Distribution

The bundle is universal (arm64 + x86_64) but **only ad-hoc signed**, so a
downloaded copy is rejected by Gatekeeper until the quarantine flag is cleared:

```
$ spctl -a -vvv -t exec HeatWatch.app
HeatWatch.app: rejected
```

Two viable paths:

1. **Free / private** — ship the ZIP or DMG from `./dist.sh` plus `INSTALL.txt`
   and let recipients run `xattr -dr com.apple.quarantine`. Works today, no
   Apple account, some friction and a scary dialog.
2. **Notarized** — Apple Developer Program, then:
   ```sh
   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
   NOTARY_PROFILE="heatwatch" ./dist.sh
   ```
   Credentials are stored once with `xcrun notarytool store-credentials`.
   Notarized builds open with no warning.

`dist.sh` builds, optionally signs and notarizes, then packages
`dist/HeatWatch-<version>.zip`, `.dmg` and `SHA256SUMS`. A Homebrew cask tap is
the other way to skip the quarantine dialog without an Apple account.

Note that the temperature API (`IOHIDEventSystemClient*`) is private, so the App
Store is not an option without running `powermetrics` behind a privileged
helper.

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

Absolute overrides disable the adaptive floor for that band. Load bands stay at
45 % / 85 % unless overridden.

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

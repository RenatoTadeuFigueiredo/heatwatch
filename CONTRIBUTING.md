# Contributing

## Build

```sh
./build.sh              # universal bundle in build/
./build/HeatWatch.app/Contents/MacOS/HeatWatch --probe
```

`--probe` is the headless check: it prints one temperature reading and one energy
ranking and exits. CI runs it on every push.

## Code layout

| Path | Responsibility |
|---|---|
| `Sources/sensors.c` | Die temperature sensors, CPU load fallback |
| `Sources/proc_sampler.c` | Per-process energy snapshots, executable path lookup |
| `Sources/TemperatureMonitor.swift` | Polling, per-machine thresholds, colour bands |
| `Sources/EnergySampler.swift` | Snapshot diffing, grouping by app, caching |
| `Sources/StatusItemController.swift` | Status item, menu rendering, login item |
| `Sources/Localization.swift` | String table lookup (en, pt-BR) |
| `tools/make_icon.swift` | Regenerates `Resources/AppIcon.icns` |

## Conventions

- Everything in English: code, comments, commit messages, pull requests. UI strings
  go through `L("key", "English fallback")` and live in both `Resources/*.lproj`.
- Keep the background path cheap. Anything that runs more often than every 10 s
  while the menu is closed needs a reason.
- Matching thresholds: a change that only works on one machine's thermal profile is
  a regression; prefer the adaptive floor.
- Commit messages follow `type(scope): description`.

## Pull requests

1. Run `./build.sh` and `--probe`; paste the probe output in the description.
2. Say which Mac and macOS version you tested on, and both architectures if the
   change touches C or IOKit code.
3. Screenshots of UI changes help; keep them under 300 KB.

## Release

Version lives in `Resources/Info.plist`. Tag `v<version>`; the release workflow
builds, packages and attaches the artifacts. Builds stay ad-hoc signed until
someone funds a Developer ID.

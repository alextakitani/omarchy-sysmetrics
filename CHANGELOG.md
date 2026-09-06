# Changelog

Notable changes to System Metrics. Versions follow [semantic versioning](https://semver.org/):
the patch digit is a fix, the minor digit adds something a config can ask for, and
nothing has needed a major bump yet.

## Unreleased

### Added

- **`showSparkline`** joins `showIcon` and `showValue`, so the strip can drop the
  plots and keep the readouts — `cpu 46%` as plain text next to the clock, with no
  patching of `BarWidget.qml`. The three toggles are independent; turning all of them
  off leaves each gauge with nothing to draw, so the widget falls back to the same
  placeholder glyph it shows when no metric is pinned, and stays clickable as a way
  back to the popup. The popup's charts are untouched either way.
  Thanks to [@gabrielforster](https://github.com/gabrielforster) ([#1](https://github.com/alextakitani/omarchy-sysmetrics/pull/1)).

- **Top-process lists for CPU and memory**, collapsed by default in the popup, so the
  question the gauges raise — *what is doing this?* — is answered in the same place.

## 1.3.0 — 2026-08-29

### Changed

- **The CPU gauge plots the busiest core instead of the average.** An average across
  cores hides exactly the case worth seeing: one core pegged at 100% while the mean
  reads a calm 12%. Urgency thresholds compare against the busiest core too.

- The marketplace listing gained a preview image, an explicit MIT license and a
  description that says what the widget does.

### Fixed

- The recurring reads are bounded at the producer rather than after the read, so an
  oversized file is dropped before it is ever materialised as a QML string.

- The hwmon name probe, the last unbounded raw read, is now bounded like the rest.

## 1.2.0 — 2026-08-27

### Changed

- **Every reader routes through the sampling gate**, not just the three that were
  named individually — an unpinned metric costs nothing while the popup is shut.

- The parsed core list is dense rather than merely capped, so a machine with many
  cores does not carry a sparse array through every sample.

### Fixed

- Recurring procfs reads are bounded before they become QML strings.

- `/proc/net/route` is bounded — the reader the previous hardening pass missed.

- An overdue `df` is killed rather than freezing storage readings forever.

### Documentation

- The documented config keys are now the ones the code actually reads.

- The contract states what the code does for every reader, and the README says what
  the widget costs to run.

## 1.1.0 — 2026-08-26

### Added

- **A three-layer test suite and CI**: the `js/` libraries under Node in milliseconds,
  the same contract under Qt's V4 engine to catch engine divergence, and a runtime
  smoke test that instantiates the production QML in a real Quickshell — the only
  layer that can see a binding which silently never fires.

### Changed

- **Each gauge repaints on its own samples**, not on every metric's. A shared counter
  repainted every canvas on the bar on each metric's sample.

### Fixed

- The `df` output reaching the storage parser is bounded, as are the recurring procfs
  readers.

### Documentation

- The detail popup appears in the README, the temperature sections are named for what
  they are, and removing the plugin is documented.

## 1.0.0 — 2026-08-25

Initial release: a strip of live CPU, memory, network, disk and GPU gauges for the
Omarchy bar, with a popup for the per-core and per-device detail behind them. Readings
come straight from `/proc` and `/sys` — no monitoring daemon, nothing to configure to
get started.

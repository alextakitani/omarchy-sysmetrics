# sysmetrics — implementation contract

Design by the architecture pass, corrected against a kernel-facts review and
verified against the target machine. Deviations need a change here first.

## Corrections applied to the original design

1. **GPU card discovery must not scan for `gpu_busy_percent` alone.** `cardN`
   numbering is not stable across reboots, and `/sys/class/drm/` also contains
   connector entries (`card1-DP-1`, `card1-HDMI-A-1`, `card1-Writeback-1` are
   all present on this machine). Match `^card[0-9]+$` only, and confirm the
   driver by reading `device/uevent` for `DRIVER=amdgpu`.

2. **`/proc/stat` totals sum the first 8 fields only.** `guest` and
   `guest_nice` are already included in `user` and `nice`; summing all 10
   double-counts. This is non-obvious — keep the comment next to the code.

3. **Byte counters exceed JS safe-integer range in principle.** `rx_bytes` is
   already 6.2e9 on this machine. Deltas stay small, so compute deltas without
   accumulating; never sum raw counters into a running total.

4. **`iowait` counts as idle, not busy.** This machine idles with a very large
   iowait (6.8e6 vs 22.5e6 idle on cpu0); counting it as busy inflates the
   graph permanently.

## Verified machine facts

| Thing | Value |
|---|---|
| CPU | AMD Ryzen 7 9700X, 16 logical cores (`cpu0..cpu15`) |
| CPU temp | hwmon named `k10temp`, labels `Tctl` (temp1), `Tccd1` (temp3) |
| GPU | amdgpu at `card1`, labels `edge` / `junction` / `mem` |
| VRAM | bytes; 1576263680 used of 12868124672 |
| Network | default route `wlp9s0` (metric 600); ignore `lo`/`docker0`/`veth*` |
| Disks | `nvme0n1`, `nvme1n1`; `zram0` has no `/sys/block/*/device` |
| NVMe temps | two hwmons named `nvme`, both expose `Composite` |

## Verified runtime facts

- `FileView.reload()` genuinely re-reads procfs: counters advance per tick
  (measured 367959 -> 368006 across 4 ticks). No subprocess needed.
- `printErrors: false` is the in-repo convention for reads that may be absent.
- `BarWidget` base supplies `setting()`, `bar`, `vertical`, `barSize`.

## Non-negotiables

- Theme tokens only (`Color.*`); no literal colors, Canvas included.
- Canvas repaints are explicit: data, colour, size, and visibility handlers.
- First counter sample renders no data, never a fake `0`.
- Pure parsing/derivation in `js/`, no Qt imports there.

## Findings from bring-up (verified on screen)

These cost a debug cycle each; they are recorded so the next change does not
reintroduce them.

1. **`Row` has no `verticalItemAlignment`** in this Qt build — assigning it
   makes the whole widget fail to load, and the bar simply renders without it.
   The failure is only visible in the Quickshell log
   (`/run/user/1000/quickshell/by-id/*/log.qslog`, readable with `strings`),
   never on screen.
2. **Never give a `Row` child a height derived from that `Row`.** `height:
   strip.height` inside the strip made the parent's implicit height depend on
   a child that depended on the parent; everything collapsed to zero width and
   the widget was invisible with no error logged at all.
3. **Nerd Font glyphs above U+FFFF do not survive a shell heredoc** — they
   arrive as empty strings. Write them as UTF-16 surrogate pairs
   (`"\uDB80\uDECA"`); a bare `\uF02CA` is parsed as `\uF02C` plus `A`.
   `U+EFC5` (RAM stick) is inside the BMP and needs no pair — and it is the
   memory icon, `U+F035B` renders as a chip.
4. **A padded ring buffer must not be plotted at its padded length.** The tail
   is "no data yet", not idle time; plotting it squeezed the real samples into
   a sliver on the left. The plot spans to the last real sample instead.
5. **Zero swap draws no swap line.** A line pinned to the floor reads as
   "swapping, barely", which is a different claim from "nothing is swapped".
6. **In the per-core grid, keep index and value adjacent.** Spreading them to
   the cell's edges put each percentage nearer the *next* core's index, and it
   read as `7%1`. Slack goes to the right of the pair, not between them.
7. **Reserve text columns at their widest value.** Percentages and core
   indices change width as they change value; a box sized to the current
   string makes the whole grid twitch, and a box sized for one digit leaves a
   two-digit index touching the glyph beside it.

## Chart form per metric (researched, not arbitrary)

One shape for every metric is wrong, and in four cases actively misleading
rather than merely plain. The rules below are the reason the code looks
inconsistent on purpose.

| Metric | Form | Axis |
|---|---|---|
| cpu | filled area | 0-100 |
| memory (+swap) | filled area, swap as second colour | 0-100 |
| vram | filled area | 0-100 |
| gpu | columns | 0-100 |
| cputemp / gputemp | **unfilled line** + threshold zone | 30-95 C band |
| network (rx/tx) | mirrored columns, shared scale | rolling max, floored |
| disk (read/write) | mirrored columns, shared scale | rolling max, floored |

Why each departure exists:

- **A fill implies a zero baseline.** Shading an area states "this much of
  something"; combining a fill with a truncated axis overstates every value.
  So a banded quantity may not be filled — temperatures are drawn as a bare
  line. The converse also holds: cpu/memory/gpu/vram are genuinely zero-based,
  so filling them is honest.
- **Temperatures need the band, not zero.** From a 0 C baseline the whole
  idle-to-throttle range occupies a couple of pixels and a thermal event looks
  like nothing. Zero is arbitrary for temperature; the meaningful range is not.
  The band is fixed (30-95), never fitted per frame — a fitted range would
  re-introduce the same exaggeration from the other direction.
- **Percentages are pinned to 0-100, never auto-scaled.** Auto-scaling makes
  idle noise look identical to a genuine pegging.
- **Two-directional rates are mirrored, not merged.** Drawing rx and tx as one
  line discards direction, which is half of what the metric says. Both
  directions share one scale, so they stay comparable.
- **A metric that rests at zero is drawn as columns.** A line interpolates
  between two near-zero samples and invents activity that never occurred.
- **Urgency is not colour alone.** Colour as the sole carrier of meaning fails
  for anyone who cannot separate the two hues, so the threshold is also a
  shaded zone — position as well as colour.
- **Columns have a minimum legible width.** Below roughly 3 px per slot they
  stop reading as bars, so a column plot shows only as many recent samples as
  it can draw, instead of cramming the full window into noise.

## Popup as the control surface

Every section is rendered whether or not its metric is pinned to the bar: the
popup is where the strip is configured, so a hidden metric still has to be
reachable to bring back. A filled dot in a section header means "on the bar",
a hollow one means "popup only"; clicking the header toggles it and writes
through `bar.shell.updateEntryInline`, the same path the clock uses.

Toggling rebuilds the list in canonical order rather than appending, so a
metric switched off and on again returns to its place in the strip instead of
jumping to the end.

Two QML traps hit while building this, both of which broke the whole panel
with no visible error beyond a log line:

- **`anchors` on an item a layout manages is undefined behaviour.** A
  MouseArea anchored across a header row inside a ColumnLayout silently stopped
  the popup from opening at all. Host it in a zero-size layout item and anchor
  from there.
- **An id declared inside a `RowLayout` is not in scope for an item reparented
  out of it.** Republish the state (here, hover) as a property on the root.

Also: `implicitHeight` is ignored for a child of a `ColumnLayout` — without
`Layout.preferredHeight` the popup charts collapsed to a sliver and looked
like they were failing to paint.

## The empty state is a real state

Turning every metric off is a decision, not an error. `normalizeMetrics` used
to restore the defaults on an empty list, which meant switching off the last
metric made two reappear on their own — the widget overriding the user. An
explicitly empty list is now preserved; only a missing or malformed `metrics`
key falls back to the defaults.

That makes the widget's empty rendering load-bearing: with nothing to draw the
strip would collapse to an invisible sliver, and the popup that turns metrics
back on would be unreachable. A dimmed chip glyph holds the widget's place and
keeps it clickable. Verified by emptying the list, reopening the popup, and
clicking a header to bring a metric back.

### Sizing traps in the header hit area

The toggle broke twice before it worked, both times silently:

- **A circular size dependency spreads the hit area.** The MouseArea took its
  height from `headerRow.implicitHeight` while the row filled the MouseArea.
  With the height undefined the hit area reached across neighbouring sections,
  and a single click toggled several metrics at once. Size the row from its own
  content and let the MouseArea follow it, never both ways.
- **A replaced block that does not match leaves nothing behind.** An edit that
  removed the old MouseArea and failed to re-insert the new one left the header
  with no hit area at all: no error, no log line, just a header that ignored
  clicks.

## Direction is shown three ways, and never summed

Network and disk each carry two directions, and all three channels of the
gauge must agree on that:

- **Plot**: mirrored columns, first direction up, second down.
- **Label**: both values with arrows (`184K down 29K up`), never `rx + tx`. A
  single total discards exactly the information the mirrored plot exists to
  show — `21M` could be all download, all upload, or any split.
- **Colour**: the second direction uses a counterpart hue derived from the
  theme's accent by rotating it, not a hardcoded value, so it follows whatever
  theme is active. It deliberately does not use `urgent`, which means
  "something is wrong" — upload and write are not problems. On a near
  monochrome theme, where there is no hue to rotate, it separates by lightness
  instead.

Swap keeps `urgent` precisely because swap in use genuinely is a warning
rather than the other half of a pair.

Letters for the disk directions (`0BR 17MW`) read as one token; arrows match
the plot's own up/down geometry and were used instead.

## Every metric owns a section

VRAM was originally a row inside Graphics, which left it pinned to the bar
with nowhere to click to remove it: a metric with a pin but no header of its
own is unreachable. Each entry in `METRIC_IDS` must have its own
`DetailSection` carrying `metricId`, `pinned` and `onPinToggled`.

### Verifying the click path

Hover and click were verified by driving a virtual pointer through
`/dev/uinput` and reading the section ids back out of the shell log, then
sweeping the cursor down the popup to map each header's real y position. Worth
knowing: a click that lands a few pixels off a header silently does nothing,
which looks exactly like a broken toggle — confirm the pointer is actually
over the header (hover fires) before concluding the handler is at fault.

## Label width is fixed by contract, not by observation

The strip used to shuffle horizontally as values changed: with eight gauges
the total swing exceeded 100px, which moves click targets under the cursor and
can change *which* gauge a click lands on.

The fix is the mechanism i3bar exposes as `min_width` accepting a **string**
rather than a number: each label lives in a box whose width is a template
string measured at runtime in the theme's own font. Nothing is hardcoded in
pixels, so it holds for whatever font a theme picks.

| Metric | Template |
|---|---|
| cpu / memory / gpu / vram | `100%` |
| cputemp / gputemp | `100°` |
| network / disk | `888M↓ 888M↑` |

`888` because 8 is among the widest digits, and a decimal point is narrower
than a digit, so `8.8M` fits wherever `888M` does.

The objection to reserving — that it wastes space — is answered by tightening
the *format* rather than by abandoning the reservation. The rate formatter is
now capped at four characters across the entire range from bytes to gigabytes:
one decimal below ten (where `1M` would otherwise cover everything from 1.0 to
1.9 MiB/s), none above it, a bare `0` when idle, and a rollover so rounding
can never produce `1024K`. With the contract tight, the reserved maximum sits
close to the typical reading.

Two rules that matter:

- **Templates come from the format contract, never from telemetry.** Sizing
  VRAM to what it "usually" reaches would make the strip shuffle exactly when
  the machine is under load — the moment you are most likely to be looking.
- **Right-align inside the box.** The unit glyph (`%`, `°`, `↑`) stays pinned
  and digits grow leftwards into the reserved gap, so the eye has a fixed
  anchor. Centring would let both edges move.

### Qt specifics

- `TextMetrics.renderType` must match the `Text.renderType` it is sizing.
  These labels use `NativeRendering`, which rasterises through the platform;
  a measurement taken under a different render type can disagree with what is
  actually drawn, which defeats the whole point of the fixed box.
- In a `Row`, set the child's explicit `width`; `implicitWidth` is the thing
  that keeps changing, and no switch makes a `Row` ignore it.
- `font.features` (for `tnum`) exists only from Qt 6.6, and is a silent no-op
  when the font lacks the feature. It is not a solution here anyway: tabular
  figures stabilise digit-to-digit width, not a change in digit *count*.

Rejected: hysteresis/ratcheting widths (still moves, just later — and a target
that resizes seconds after the event that caused it is more disorienting than
one that resizes immediately), and padding with figure spaces (U+2007 relies
on the resolved font having a digit-width glyph for it).

Verified by fingerprinting the bar's bright-column positions idle versus under
full CPU, network and disk load: the last bright column sat at x=1124 in both,
a shift of zero, while the readings moved from `1%`/`55°`/`5.1K` to
`14%`/`74°`/`17K`.

## In-place mutation is invisible to QML bindings

`ringPush` mutates the ring buffer in place. QML compares the *reference* when
deciding whether a binding needs re-evaluating, and the reference never
changes — so a binding that reads `Engine.ringValues(sampler.cpuHistory)`
directly is evaluated once, at creation, and never again. The popup's charts
sat permanently empty because of this: the ring held 60 slots of NaN from
before the first sample, and nothing ever asked for it again.

The bar dodged it by accident: its series go through helper functions that
touch `sampler.revision` first, which states the dependency. The popup sections
read the rings directly and had no such dependency.

Every binding that reads a ring must state the dependency explicitly:

```qml
readonly property int revisionTick: sampler ? sampler.revision : 0

primary: {
  void root.revisionTick
  return root.sampler ? Engine.ringValues(root.sampler.cpuHistory) : []
}
```

This is the same class of bug as the hwmon discovery failure earlier in this
file, where a mutated-and-reassigned object did not fire its change signal.
When a value lives behind a reference that is reused, assume QML will not
notice — say what it depends on.

Diagnosing it: the symptom is an empty chart, and the useful signal is
`lastReal=-1` alongside `len=60` — a full-length buffer whose entries are all
NaN, meaning nothing was ever pushed *as far as this reader is concerned*.
Beware that adding a `Connections` block inside a component whose default
property is a content list fails with "Cannot assign object of type
QQmlConnections to list property", which silently makes the whole section
unavailable and looks like a different bug entirely.

## One counter per metric, not one for everything

`revision` states the dependency that in-place ring mutation hides (previous
section). But a *single* counter says "something changed", and every view
reading it re-evaluates on every metric's sample — a CPU tick invalidated the
network gauge's bindings and repainted its canvas, which does a full
`ctx.reset()`, trough fill and 60-point sweep for data that did not move.

The cost is multiplicative: N gauges on the bar, M metrics sampled per tick,
N x M repaints where N would do. With the popup open and all nine sections
live, one tick cost over a hundred invalidations instead of eleven.

So each metric owns a counter, read through `sampler.revisionOf(id)`:

```qml
readonly property int revisionTick: sampler ? sampler.revisionOf("cpu") : 0
```

`revision` stays as the any-metric counter for anything that genuinely
depends on everything. A view that draws one metric must not use it.

Measured with two metrics pinned and the popup shut: 6 invalidations per tick
became 2. Parsing, for scale, is 24us per tick for all six readers combined —
the sampling side was never the expensive half, the repaint fan-out was.

## Uptime is popup-only

`/proc/uptime` was read every tick, all day, for a number drawn only in the
popup header. `FileView` loads once when its path is set, so the boot read
still populates the header correctly on first open; the per-tick `reload()`
now happens only while the popup is actually up. Verified by counting
reloads across a popup toggle: 8 ticks with the popup shut cost 1 read (the
boot one), not 8.

## Sampling follows visibility, not just the pin

Two separate questions, and they were conflated:

- `enabled(id)` — is this metric pinned to the bar? Governs what the strip draws.
- `sampling(id)` — is it worth reading right now? `popupOpen || enabled(id)`.

A metric that is not pinned still has a section in the popup, and that section
is dead weight without live data. While the popup is open everything is
sampled; closed, only the pinned set costs anything. The extra cost is bounded:
these are all /proc and /sys reads on a 2s timer, and only while a popup the
user is actively looking at is open.

**Hardware discovery must not follow that gate.** The GPU and hwmon probes are
declared unconditionally. Hanging them off `want*` — which now depend on
`popupOpen` — would tear the probes down and rebuild them on every open, and a
metric could be sampled before its device had been found. Discovery is cheap,
runs once, and both surfaces need its result.

Verified by pinning only `cpu` and opening the popup under network and disk
load: every section drew live data, with the unpinned ones showing hollow pins.

## Spacing hierarchy, and the pin

Gaps must grow with the level they separate. This was inverted: sections sat
`space(3)` apart while their own contents used `space(6)`, so a row belonging
to one metric read as more related to the next metric's heading than to its
own section. The order is now:

| Gap | Separates | Value |
|---|---|---|
| Tightest | rows inside one section | `space(5)` |
| Middle | separator / header / content within a section | `space(7)` |
| Widest | one section from the next | `space(14)` |

A chart also carries `Layout.bottomMargin`: it is a block, not a row, and
needs more air beneath it than the label rows need between themselves.

### Sticky pin

`Ui.KeyboardPanel` dismisses on outside click via its own `dismissArea`, with
no public opt-out. The panel intercepts dismissal instead: `close()` returns
early while `sticky` is set, and `forceClose()` bypasses the guard for the
paths that must always work (the pin itself, and toggling from the widget) so
there is always a way out. `closeForPopoutSwitch` is guarded the same way, or
the bar would steal the panel away when another popout opens.

The pin's state is carried by the glyph's shape (filled `U+F0403` versus
outlined `U+F0930`) as well as by colour, so it does not depend on telling two
theme colours apart.

## Storage capacity, and the one permitted subprocess

Capacity ("how full") is a different metric from disk I/O ("how busy"), and
the popup names them **Storage** and **Disk I/O** so the two are not confused.

Capacity is the single reading that cannot come from `/proc` or `/sys`: it
needs `statvfs()`, which QML does not expose and procfs does not carry. So
`df` is run as a subprocess — coreutils, not a monitoring daemon, and measured
at about 2ms. Two things keep the cost honest:

- It runs on its own slow cadence (every ~15 ticks), because disk usage moves
  over minutes, not seconds.
- Like every other popup-only reading, it runs only while something needs it.

Parsing notes: subvolumes and bind mounts report the same underlying
filesystem, so rows are collapsed by their size/used pair with the shallowest
mount point kept as the name — on this machine that folds five rows into `/`.
Anything under a gibibyte is dropped, which removes pseudo-filesystems like
`/sys/firmware/efi/efivars` that otherwise appear with a real-looking 57%.

The mount table is user-controlled input — FUSE mounts can be created in a
loop, with mount points of any length — so `df` is capped at 64 KiB by
`head -c` before its output ever becomes a QML string, then capped again at
32 rows and 128 characters of mount point. See *Every recurring reader is
bounded* below for why.

## Every recurring reader is bounded

The plugin runs inside the shared shell process. Anything unbounded here is
not a widget that misbehaves — it is the user's whole desktop, and on the
sampling timer it is that cost repeated forever.

So no reader trusts the size of what it reads, `/proc` and `/sys` included.
Their *contents* come from the kernel, but their row counts and their names
do not: interfaces can be added in bulk with `ip link add`, block devices
come and go, mount points are paths a user chose. Each reader therefore
carries three ceilings, named as constants next to the parser that enforces
them:

| Reader | Bytes | Rows | Name |
| --- | --- | --- | --- |
| `df` (storage) | 64 KiB, at the pipe | 32 | 128 chars of mount point |
| `/proc/net/dev` | 256 KiB | 128 interfaces | 64 chars |
| `/proc/diskstats` | 256 KiB | 128 devices | 64 chars |
| `/proc/stat` | 256 KiB | 1024 cores | — |

Two rules hold across all of them:

- **Fail closed on truncation.** Input at or past its byte ceiling is
  discarded whole, never parsed to a torn final row. A metric that reads as
  unavailable is honest; a number assembled from half a line is not.
- **The ceiling is not a display limit.** It is the point past which the
  input has stopped describing this machine. A real host has tens of
  interfaces, not thousands; the kernel emits `cpu0..cpuN-1` densely, so a
  core index outside the ceiling is not a core being missed.

That last one has teeth in `/proc/stat`: the core index is written straight
into a sparse array, so it sets the array's length. A single
`cpu2000000000` line would make every consumer that walks `cores.length`
loop two billion times per tick.

### The byte ceiling is enforced before the read becomes a string

A ceiling checked inside the parser is checked too late. `FileView.text()`
has by then read the whole file and converted every byte of it to UTF-16, so
the allocation the ceiling exists to prevent has already happened; the parser
only declines to *retain* it. For a reader on the sampling timer that is the
cost that matters.

So the byte ceiling is enforced at the read, by `Readers.boundedText()`,
which measures `FileView.data().byteLength` — an `ArrayBuffer`, so the size
is known without paying for the conversion — and returns `""` rather than
calling `text()` when the file is at or past `PROC_MAX_BYTES`. Every
recurring `FileView` reader goes through it. `df` is bounded a step earlier
still, by `head -c` in the pipe, where the ceiling is the kernel's to enforce
and the oversized bytes never enter the process at all.

The parser-side checks stay exactly where they are. They are the same rule
enforced one layer in, for callers that reach a parser without coming through
a reader — the unit suite does precisely that, and so would any future
caller. Two layers, one constant: `boundedText` gates on the
`Parsers.PROC_MAX_BYTES` the parsers themselves use, so the two cannot drift.

`sh -c … | head -c` was considered for the procfs readers too, for symmetry
with `df`, and rejected on measurement: a spawn costs ~0.9 ms against a
~0.01 ms `FileView` read, and these three run *every* tick where `df` runs
every fifteenth. That is ~2.7 ms of fork/exec per second on every machine
forever, to bound a flood that on the root netns needs `CAP_NET_ADMIN` to
produce. The in-process gate costs one `byteLength` read and bounds the same
thing.

## Uptime and the interval control

The popup header carries `up 7h 45m` and a `refresh − + 2000 ms` stepper.

A freshness readout ("just now" / "5s ago") was tried and removed: with a two
second poll it could practically never say anything but "just now", so it
occupied a line without carrying information. Its one-second ticker went with
it. The idea was to expose a silently stopped sampler; if that is ever wanted
back, it should surface only *past* a staleness threshold rather than
displaying an age that is almost always zero. The backing properties
(`lastSampleAt`, `freshnessTick`, `secondsSinceSample`) outlived the readout
by mistake, costing a `Date.now()` per tick for a value with no consumer;
they are gone now.

The stepper is labelled because a bare `− + 2000 ms` does not say what it
governs. It writes through the same `updateEntryInline` path as the metric
pins, and clamps to the range the config normaliser enforces so a click can
never write a value that would be silently replaced.

## No hover tooltip

The bar strip has no hover tooltip. It previously showed the same numbers the
popup does, which made it a second, worse copy of that information that
appeared uninvited whenever the pointer crossed the bar. Clicking opens the
popup; hovering does nothing. `WidgetButton.tooltipText` simply stays at its
empty default, which `Bar.showTooltip` already guards against.

## The popup anchors by its right edge

The popup used to anchor to the bar button itself. Toggling a metric changes
the strip's width, which moved the button, which moved the popup — sideways,
under the cursor, while the user was clicking pins inside it. Every toggle
shifted the next target.

`KeyboardPanel` positions the card as `anchorScreenPos.x + anchorW/2 -
contentWidth/2`, so the card is centred on its anchor item. The widget
therefore exposes a marker pinned to its own right edge, sized to the card's
width: centring a card on a marker of equal width lands the two right edges on
each other. The widget's right edge is the part that does not move when the
strip grows leftwards, so the popup stays put.

Verified by pinning the popup open, toggling a metric from inside it, and
comparing the header region before and after: 0.09% of pixels differed, all of
it the uptime text advancing.

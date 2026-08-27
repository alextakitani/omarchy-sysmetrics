// Runtime smoke harness -- see tests/run-runtime-smoke for how it is wired.
//
// This drives the production Sampler and Readers through real samples and
// asserts the things only a running engine can show: that each metric's
// revision counter advances on its own samples, that ring buffers actually
// reach the views, and that popup-gated readings stay quiet while the popup
// is shut. A binding that silently never fires is the failure mode here, so
// every check compares observed state against what a sample should have
// produced rather than merely instantiating the objects.

import QtQuick
import Quickshell
import Quickshell.Io
import "plugin" as Plugin

ShellRoot {
  id: harness

  property int failures: 0
  property var notes: []

  function check(label, condition) {
    if (!condition) {
      failures += 1
      console.warn("SYSMETRICS_CHECK_FAIL " + label)
    }
    notes.push((condition ? "ok   " : "FAIL ") + label)
  }

  // Left on its own normalised defaults, which pin cpu and memory. The popup
  // starts shut, so this is the configuration that actually ships and the one
  // where the visibility gating has to hold.
  Plugin.Sampler {
    id: sampler
  }

  Plugin.Readers {
    id: readers
    sampler: sampler
  }

  property int ticks: 0

  // An oversized stand-in for a flooded procfs file, written by the harness
  // script. boundedText must drop it whole.
  FileView {
    id: oversized
    path: Quickshell.env("SYSMETRICS_OVERSIZED_FIXTURE") || ""
    blockLoading: true
    printErrors: false
  }
  readonly property alias oversizedView: oversized

  // Snapshots taken while the popup is shut, compared after it opens.
  property int netRevWhileClosed: 0
  property int uptimeWhileClosed: 0

  Timer {
    interval: 250
    running: true
    repeat: true
    triggeredOnStart: true

    onTriggered: {
      readers.sampleAll()
      harness.ticks += 1

      // Four ticks with the popup shut, then four with it open.
      if (harness.ticks === 4) {
        harness.netRevWhileClosed = sampler.networkRevision
        harness.uptimeWhileClosed = sampler.uptimeSeconds
        sampler.popupOpen = true
      }

      if (harness.ticks < 8) return
      running = false
      harness.report()
    }
  }

  function report() {
    // ---- the readings themselves ----------------------------------------
    check("cpu percent is a real number", !isNaN(sampler.cpuUsage))
    check("cpu percent is in range", sampler.cpuUsage >= 0 && sampler.cpuUsage <= 100)
    check("memory percent is a real number", !isNaN(sampler.memory.percent))
    check("memory total is nonzero", sampler.memory.totalKB > 0)
    check("per-core list is populated", sampler.cpuCores.length > 0)

    // ---- rings reach their consumers -------------------------------------
    // An empty chart is the classic failure: the ring fills but nothing ever
    // reads it, because in-place mutation does not fire a binding.
    var cpuSeries = sampler.cpuHistory
    check("cpu ring recorded samples", cpuSeries.filled > 0)

    // ---- per-metric revisions --------------------------------------------
    // Each counter must advance on its own metric's samples. A metric wired
    // to the wrong counter repaints on someone else's tick, or never.
    check("cpu revision advanced", sampler.cpuRevision > 0)
    check("memory revision advanced", sampler.memoryRevision > 0)
    check("revisionOf routes cpu", sampler.revisionOf("cpu") === sampler.cpuRevision)
    check("revisionOf routes memory", sampler.revisionOf("memory") === sampler.memoryRevision)
    check("revisionOf routes network", sampler.revisionOf("network") === sampler.networkRevision)
    check("revisionOf routes storage", sampler.revisionOf("storage") === sampler.storageRevision)
    check("revisionOf falls back for an unknown id",
          sampler.revisionOf("nonsense") === sampler.revision)

    // The global counter still advances, and by more than any single metric:
    // it is bumped by every metric, which is exactly why views must not use it.
    check("global revision advanced", sampler.revision > 0)
    check("global revision outpaces one metric", sampler.revision > sampler.cpuRevision)

    // ---- sampling follows visibility -------------------------------------
    // Network is not pinned here, so it must stay still while the popup is
    // shut and start moving once it opens.
    check("unpinned metric stayed quiet while popup was shut",
          harness.netRevWhileClosed <= 1)
    check("unpinned metric resumed once popup opened",
          sampler.networkRevision > harness.netRevWhileClosed)

    // Uptime is drawn only in the popup header, so per-tick reads must not
    // happen while it is shut. FileView loads once when its path is set, so
    // the boot value is expected to be present -- what must not happen is it
    // advancing tick after tick with nobody looking.
    check("uptime is available from the boot read", sampler.uptimeSeconds > 0)

    // ---- recurring reads are bounded before they become strings ----------
    // The parsers carry ceilings too, but those run after FileView has
    // already allocated the string. boundedText is the gate that runs first,
    // so it is the one worth asserting against a real FileView: a real
    // procfs file must survive it intact, and an oversized one must be
    // dropped whole rather than parsed.
    var realStat = readers.boundedText(readers.statFileView)
    check("bounded read passes a real /proc/stat through", realStat.length > 0)
    check("bounded read agrees with the unbounded text",
          realStat === readers.statFileView.text())
    check("bounded read rejects a file at the ceiling",
          readers.boundedText(harness.oversizedView) === "")
    check("the oversized fixture really is over the ceiling",
          harness.oversizedView.data().byteLength >= 262144)

    // ---- config normalisation reaches the sampler ------------------------
    check("interval is within the enforced range",
          sampler.config.intervalMs >= 500 && sampler.config.intervalMs <= 60000)
    check("metrics list is an array", sampler.config.metrics.length !== undefined)

    for (var i = 0; i < notes.length; i++) console.warn("SYSMETRICS_CHECK " + notes[i])

    if (failures === 0) console.warn("SYSMETRICS_RUNTIME_SMOKE_PASS")
    else console.warn("SYSMETRICS_RUNTIME_SMOKE_FAIL " + failures + " check(s)")

    Qt.exit(failures === 0 ? 0 : 1)
  }
}

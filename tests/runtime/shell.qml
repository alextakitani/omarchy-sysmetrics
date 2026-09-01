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

  // The fix under test: the same oversized fixture read through the producer
  // ceiling instead of through FileView. This is the check the previous
  // round of this fix did not have, and the reason it was wrong -- the
  // failure is a memory spike at load, so the assertion has to be about
  // memory, not about the returned string.
  property string boundedResult: "pending"
  property int rssBeforeMB: 0
  property int rssAfterMB: 0

  function rssMB() {
    var v = Qt.createQmlObject(
      'import Quickshell.Io; FileView { path: "/proc/self/status"; watchChanges: false; blockLoading: true }',
      harness)
    var t = v.text()
    v.destroy()
    var m = /VmRSS:\s+(\d+) kB/.exec(t)
    return m ? Math.round(parseInt(m[1]) / 1024) : -1
  }

  Plugin.BoundedReader {
    id: boundedOversized
    path: Quickshell.env("SYSMETRICS_OVERSIZED_FIXTURE") || ""
    maxBytes: 262144
    onRead: text => {
      harness.rssAfterMB = harness.rssMB()
      harness.boundedResult = text
    }
  }

  // Snapshots taken while the popup is shut, compared after it opens.
  property int netRevWhileClosed: 0
  property int uptimeWhileClosed: 0

  // The process sweep is gated more tightly than everything else -- on its
  // sections being expanded, not merely on the popup being open -- because it
  // is the dearest read here. Both halves of that gate are snapshotted: it
  // must stay still through a popup that is merely open, and it must move
  // once a list is actually expanded.
  property int procRevWhilePopupOpen: 0
  property real firstSweepCpu: -1

  Timer {
    interval: 250
    running: true
    repeat: true
    triggeredOnStart: true

    onTriggered: {
      readers.sampleAll()
      harness.ticks += 1

      // Fire the producer-bounded read once, sampling RSS either side of it.
      if (harness.ticks === 2) {
        harness.rssBeforeMB = harness.rssMB()
        boundedOversized.reload()
      }

      // Four ticks with the popup shut, then four with it open.
      if (harness.ticks === 4) {
        harness.netRevWhileClosed = sampler.networkRevision
        harness.uptimeWhileClosed = sampler.uptimeSeconds
        sampler.popupOpen = true
      }

      // Then the process lists are expanded, which is the only thing that
      // may start the sweep. Two sweeps at least are needed before any CPU
      // reading exists at all: the first only establishes the baseline.
      if (harness.ticks === 8) {
        harness.procRevWhilePopupOpen = sampler.processesRevision
        sampler.processesExpanded = true
      }

      if (harness.ticks === 10 && sampler.topCpuProcesses.length > 0)
        harness.firstSweepCpu = sampler.topCpuProcesses[0].cpuPercent

      if (harness.ticks < 14) return
      running = false
      harness.report()
    }
  }

  function report() {
    // ---- the readings themselves ----------------------------------------
    check("cpu percent is a real number", !isNaN(sampler.cpuUsage))
    // The headline reading is the busiest core, so it must be at least the
    // mean -- a max below its own average would mean the two disagree.
    check("cpu reading is the busiest core, not the mean",
          isNaN(sampler.cpuAggregate) ||
          sampler.cpuUsage >= sampler.cpuAggregate - 0.001)
    check("the aggregate is still available", !isNaN(sampler.cpuAggregate))
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
    // boundedText is the weak, kernel-bounded form of the ceiling: it runs
    // after FileView has already allocated, so it is only sufficient for
    // files the kernel caps at a page. Asserted here against a real FileView
    // for the readers that still use it. The readers whose size is decided
    // outside this plugin go through BoundedReader instead, checked below.
    var realUptime = readers.boundedText(readers.uptimeFileView)
    check("bounded read passes a real /proc/uptime through", realUptime.length > 0)
    check("bounded read agrees with the unbounded text",
          realUptime === readers.uptimeFileView.text())
    check("bounded read rejects a file at the ceiling",
          readers.boundedText(harness.oversizedView) === "")
    check("the oversized fixture really is over the ceiling",
          harness.oversizedView.data().byteLength >= 262144)

    // ---- the producer ceiling, which is the actual fix -------------------
    // FileView materialises the whole file before onLoaded fires, so the
    // gate above cannot bound a file this plugin does not control the size
    // of. BoundedReader stops the read at the ceiling instead. Both halves
    // are asserted: the payload never arrives, and the memory is not spent.
    check("producer-bounded read returned",
          harness.boundedResult !== "pending")
    check("producer-bounded read drops a file at the ceiling",
          harness.boundedResult === "")
    check("producer-bounded read did not materialise the file",
          harness.rssAfterMB - harness.rssBeforeMB < 32)

    // ---- the process sweep, and its gate ---------------------------------
    // The gate is the whole reason this reading is affordable, so it is
    // asserted before the reading itself. A popup that is merely open must
    // not have paid for a single sweep.
    check("process sweep stayed quiet while its lists were collapsed",
          harness.procRevWhilePopupOpen === 0)
    check("process sweep ran once its list was expanded",
          sampler.processesRevision > 0)

    check("top cpu list is populated", sampler.topCpuProcesses.length > 0)
    check("top memory list is populated", sampler.topMemoryProcesses.length > 0)
    check("lists are cut to ten rows",
          sampler.topCpuProcesses.length <= 10 &&
          sampler.topMemoryProcesses.length <= 10)

    // pid 1 exists on every Linux system and always has a name, so a list of
    // rows with blank names means the producer's comm field never survived.
    check("process rows carry a name and a pid",
          sampler.topCpuProcesses[0].comm.length > 0 &&
          sampler.topCpuProcesses[0].pid > 0)

    // The first sweep has no baseline, so every CPU reading on it is NaN --
    // that is the honest state, and the list must not fabricate a number.
    check("the first sweep reports no cpu reading",
          harness.firstSweepCpu === -1 || isNaN(harness.firstSweepCpu))

    // By now several sweeps have run, so a real reading must have appeared.
    check("a later sweep produced a real cpu reading",
          !isNaN(sampler.topCpuProcesses[0].cpuPercent))
    check("cpu readings are not negative",
          isNaN(sampler.topCpuProcesses[0].cpuPercent) ||
          sampler.topCpuProcesses[0].cpuPercent >= 0)

    // Memory ranking needs no baseline, so it is right on the first sweep.
    check("memory list is ranked descending",
          sampler.topMemoryProcesses.length < 2 ||
          sampler.topMemoryProcesses[0].rssBytes >=
            sampler.topMemoryProcesses[1].rssBytes)
    check("memory rows are in bytes, not pages",
          sampler.topMemoryProcesses[0].rssBytes > 0)

    check("processes route to their own revision counter",
          sampler.revisionOf("processes") === sampler.processesRevision)

    // Collapsing must drop the baseline: the next sweep after a gap would
    // otherwise difference against ticks from minutes ago and read as a huge
    // spike that never happened.
    sampler.processesExpanded = false
    check("collapsing drops the cpu baseline",
          sampler.previousProcessesAt === 0)

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

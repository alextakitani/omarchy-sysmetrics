import QtQuick
import Quickshell.Io
import "js/parsers.js" as Parsers
import "js/engine.js" as Engine
import "js/config.js" as Config

// Non-visual sampling core: owns the timer, every FileView, and the derived
// state for each enabled metric. Views bind to the state and repaint on
// `updated`; nothing here paints or lays out.
//
// Everything is read from /proc and /sys through FileView. reload() genuinely
// re-reads a procfs file (pseudo-files must be re-read from offset zero, which
// is what reload does), so no subprocess is ever spawned.
QtObject {
  id: sampler

  property var config: Config.normalizeConfig({})
  property bool popupOpen: false

  // The process lists are collapsed by default and sample only while open,
  // so the popup tells the sampler whether either one is expanded. This is
  // the one reading gated on something finer than `popupOpen`: a full /proc
  // sweep is far dearer than any other read here, and it is the only one
  // whose section is hidden until asked for.
  property bool processesExpanded: false

  // Bumped on every committed sample. Canvas does not repaint on binding
  // changes, so views hang their requestPaint() off this.
  //
  // `revision` is the any-metric counter, kept for readings that genuinely
  // depend on everything. Anything that belongs to ONE metric must use that
  // metric's own counter below instead: with a single shared counter, a CPU
  // sample invalidated the network gauge's bindings and repainted its canvas
  // too, so N pinned metrics cost N repaints per sample each rather than one.
  // Same in the popup, multiplied by every open section.
  //
  // These are read through revisionOf(id), which keeps the view code free of
  // per-metric plumbing.
  property int revision: 0

  property int cpuRevision: 0
  property int memoryRevision: 0
  property int networkRevision: 0
  property int diskRevision: 0
  property int gpuRevision: 0
  property int vramRevision: 0
  property int storageRevision: 0
  property int cputempRevision: 0
  property int gputempRevision: 0
  property int processesRevision: 0

  // The repaint dependency for one metric. A view that draws a single metric
  // states this rather than `revision`, so it is invalidated only by its own
  // samples.
  function revisionOf(id) {
    if (id === "cpu") return cpuRevision
    if (id === "memory") return memoryRevision
    if (id === "network") return networkRevision
    if (id === "disk") return diskRevision
    if (id === "gpu") return gpuRevision
    if (id === "vram") return vramRevision
    if (id === "storage") return storageRevision
    if (id === "cputemp") return cputempRevision
    if (id === "gputemp") return gputempRevision
    if (id === "processes") return processesRevision
    return revision
  }

  signal updated(string metricId)

  // Pinned to the bar. Governs what the strip draws.
  function enabled(id) {
    return config.metrics.indexOf(id) >= 0
  }

  // Worth sampling right now. A metric that is not on the bar still has a
  // section in the popup, and that section is useless without live data — so
  // while the popup is open everything is sampled, not just the pinned set.
  // Closed, only the pinned metrics cost anything.
  function sampling(id) {
    return popupOpen || enabled(id)
  }

  // ---- CPU ---------------------------------------------------------------

  // The busiest logical core, not the mean across all of them.
  //
  // The kernel's aggregate `cpu` line averages every core, which hides the
  // load people actually want to see: on a 16-core machine one core pegged
  // at 93% reads as 7% aggregate, so a compile or any single-threaded job
  // barely moves the graph. The max is what answers "is something working
  // hard right now", so it is what the strip plots and what `cpu.urgent`
  // compares against.
  //
  // cpuAggregate keeps the mean, because "how loaded is the machine overall"
  // is still the right question for the popup to answer alongside it.
  property real cpuUsage: NaN
  property real cpuAggregate: NaN
  property var cpuCores: []           // current percent per logical core
  property var cpuHistory: Engine.makeRing(60)
  property var previousCpuAggregate: null
  property var previousCpuCores: []
  property var loadAverage: ({ one: NaN, five: NaN, fifteen: NaN })

  function applyProcStat(text) {
    var parsed = Parsers.parseProcStat(text)
    if (!parsed.aggregate) return

    var aggregate = Engine.cpuBusyPercent(previousCpuAggregate, parsed.aggregate)
    cpuAggregate = aggregate === null ? NaN : aggregate
    previousCpuAggregate = parsed.aggregate

    // Per-core is parsed on every tick, popup open or not: it rides along in
    // the same read the aggregate already needs, and gating it would break
    // delta continuity so the grid would be blank each time the popup opens.
    // It is also what the headline reading is derived from, so it is not
    // popup-only detail any more.
    var cores = []
    var busiest = NaN
    for (var i = 0; i < parsed.cores.length; i++) {
      var perCore = Engine.cpuBusyPercent(previousCpuCores[i], parsed.cores[i])
      var value = perCore === null ? NaN : perCore
      cores.push(value)
      if (!isNaN(value) && (isNaN(busiest) || value > busiest)) busiest = value
    }
    cpuCores = cores
    previousCpuCores = parsed.cores

    // Fall back to the aggregate when there are no per-core lines to read
    // (a first sample, a counter reset, or a kernel that gave us none), so
    // the reading degrades to the old behaviour rather than to nothing.
    var usage = isNaN(busiest) ? cpuAggregate : busiest

    // A NaN here means there is no measurable interval yet (first sample, or
    // a counter reset). Pushing NaN keeps the plot honest instead of drawing
    // a dip to zero that never happened.
    Engine.ringPush(cpuHistory, usage)
    cpuUsage = usage

    cpuRevision += 1
    revision += 1
    updated("cpu")
  }

  // ---- Memory ------------------------------------------------------------

  property var memory: ({ percent: NaN, usedKB: 0, totalKB: 0, availableKB: 0,
                          cachedKB: 0, buffersKB: 0, swapTotalKB: 0, swapUsedKB: 0 })
  property var memoryHistory: Engine.makeRing(60)
  property var swapHistory: Engine.makeRing(60)

  function applyMeminfo(text) {
    var parsed = Parsers.parseMeminfo(text)
    memory = parsed
    Engine.ringPush(memoryHistory, parsed.percent)
    // Swap is plotted against the same 0-100 axis as RAM so the two are
    // directly comparable; a machine with no swap contributes nothing.
    // A swap line pinned to the floor reads as "swap is being used, barely",
    // which is a different claim from "nothing is swapped". Untouched swap
    // contributes no point at all, so the line simply is not drawn.
    var swapPercent = (parsed.swapTotalKB > 0 && parsed.swapUsedKB > 0)
      ? (parsed.swapUsedKB * 100 / parsed.swapTotalKB)
      : NaN
    Engine.ringPush(swapHistory, swapPercent)
    memoryRevision += 1
    revision += 1
    updated("memory")
  }

  // ---- Network -----------------------------------------------------------

  property string networkInterface: ""
  property real networkRx: NaN
  property real networkTx: NaN
  property var networkRxHistory: Engine.makeRing(60)
  property var networkTxHistory: Engine.makeRing(60)
  property var previousNetwork: null
  property real previousNetworkAt: 0

  function resolveInterface(routeText) {
    var configured = String(config.network.interface)
    if (configured !== "auto") return configured
    var detected = Parsers.parseDefaultIface(routeText)
    return detected ? detected : ""
  }

  function applyNetDev(text) {
    var table = Parsers.parseNetDev(text)
    var name = networkInterface
    var current = name ? table[name] : null
    var now = Date.now()

    if (!current) {
      // The interface vanished (down, renamed, unplugged). Drop the baseline:
      // deltas across two different interfaces are meaningless.
      previousNetwork = null
      networkRx = NaN
      networkTx = NaN
      Engine.ringPush(networkRxHistory, NaN)
      Engine.ringPush(networkTxHistory, NaN)
      networkRevision += 1
      revision += 1
      updated("network")
      return
    }

    var dt = previousNetworkAt > 0 ? now - previousNetworkAt : 0
    var rx = Engine.rateBetween(previousNetwork ? previousNetwork.rxBytes : null, current.rxBytes, dt)
    var tx = Engine.rateBetween(previousNetwork ? previousNetwork.txBytes : null, current.txBytes, dt)

    networkRx = rx === null ? NaN : rx
    networkTx = tx === null ? NaN : tx
    Engine.ringPush(networkRxHistory, networkRx)
    Engine.ringPush(networkTxHistory, networkTx)

    previousNetwork = current
    previousNetworkAt = now
    networkRevision += 1
    revision += 1
    updated("network")
  }

  // ---- Disk --------------------------------------------------------------

  property real diskRead: NaN
  property real diskWrite: NaN
  property var diskReadHistory: Engine.makeRing(60)
  property var diskWriteHistory: Engine.makeRing(60)
  property var diskDevices: ({})       // name -> { read, write } current rates
  property var previousDisk: null
  property real previousDiskAt: 0

  function selectedDisks(table) {
    var configured = config.disk.devices
    if (configured === "auto") return Object.keys(table)
    return Array.isArray(configured) ? configured : [String(configured)]
  }

  function applyDiskstats(text) {
    var table = Parsers.parseDiskstats(text)
    var now = Date.now()
    var dt = previousDiskAt > 0 ? now - previousDiskAt : 0
    var names = selectedDisks(table)

    var totalRead = 0
    var totalWrite = 0
    var sawAny = false
    var perDevice = {}

    for (var i = 0; i < names.length; i++) {
      var name = names[i]
      var current = table[name]
      if (!current) continue
      var previous = previousDisk ? previousDisk[name] : null
      // Sector counters are always 512-byte units, whatever the drive's
      // physical block size reports.
      var read = Engine.rateBetween(previous ? previous.readSectors * 512 : null, current.readSectors * 512, dt)
      var write = Engine.rateBetween(previous ? previous.writeSectors * 512 : null, current.writeSectors * 512, dt)
      perDevice[name] = { read: read === null ? NaN : read, write: write === null ? NaN : write }
      if (read !== null && write !== null) {
        totalRead += read
        totalWrite += write
        sawAny = true
      }
    }

    diskDevices = perDevice
    diskRead = sawAny ? totalRead : NaN
    diskWrite = sawAny ? totalWrite : NaN
    Engine.ringPush(diskReadHistory, diskRead)
    Engine.ringPush(diskWriteHistory, diskWrite)

    previousDisk = table
    previousDiskAt = now
    diskRevision += 1
    revision += 1
    updated("disk")
  }

  // ---- Filesystem capacity -----------------------------------------------

  property var filesystems: []        // [{ target, sizeBytes, usedBytes, availBytes, percent }]
  property var storageHistory: Engine.makeRing(60)

  readonly property real storagePercent: filesystems.length > 0 ? filesystems[0].percent : NaN

  function applyDf(text) {
    filesystems = Parsers.parseDf(text)
    Engine.ringPush(storageHistory, storagePercent)
    storageRevision += 1
    revision += 1
    updated("storage")
  }

  // ---- Uptime --------------------------------------------------------------

  property real uptimeSeconds: NaN

  function applyUptime(text) {
    uptimeSeconds = Parsers.parseUptimeSeconds(text)
    revision += 1
  }

  // ---- GPU ---------------------------------------------------------------

  property string gpuCard: ""          // e.g. "card1", resolved by driver, not by number
  property real gpuUsage: NaN
  property var gpuHistory: Engine.makeRing(60)
  property real gpuVramUsed: NaN
  property real gpuVramTotal: NaN
  property var vramHistory: Engine.makeRing(60)

  readonly property real vramPercent: (gpuVramTotal > 0 && !isNaN(gpuVramUsed))
    ? (gpuVramUsed * 100 / gpuVramTotal)
    : NaN

  function applyGpuBusy(text) {
    var value = Parsers.parseFirstNumber(text)
    gpuUsage = value
    Engine.ringPush(gpuHistory, value)
    gpuRevision += 1
    revision += 1
    updated("gpu")
  }

  function recordVram() {
    Engine.ringPush(vramHistory, vramPercent)
    vramRevision += 1
    revision += 1
    updated("vram")
  }

  // ---- Temperature -------------------------------------------------------

  property string temperatureLabel: ""
  property real temperature: NaN
  property var temperatureHistory: Engine.makeRing(60)

  // GPU temperature is a separate sensor on a separate chip, so it is its own
  // metric rather than a second reading of "temperature".
  property real gpuTemperature: NaN
  property var gpuTemperatureHistory: Engine.makeRing(60)
  property var temperatureSensors: []  // [{ label, celsius }] for the popup

  function applyTemperature(text) {
    var celsius = Parsers.parseHwmonMillidegrees(text)
    temperature = celsius
    Engine.ringPush(temperatureHistory, celsius)
    cputempRevision += 1
    revision += 1
    updated("cputemp")
  }

  function applyGpuTemperature(text) {
    var celsius = Parsers.parseHwmonMillidegrees(text)
    gpuTemperature = celsius
    Engine.ringPush(gpuTemperatureHistory, celsius)
    gputempRevision += 1
    revision += 1
    updated("gputemp")
  }

  // ---- Processes ---------------------------------------------------------
  // Popup-only, and only while its sections are expanded: a full sweep of
  // /proc is the most expensive read here, and nobody is looking at a list
  // that is collapsed.

  property var topCpuProcesses: []      // [{ pid, comm, cpuPercent, rssBytes }]
  property var topMemoryProcesses: []
  property var previousProcessTicks: ({})
  property real previousProcessesAt: 0
  // Page size is the producer's to report -- it comes back on the sweep's
  // first line rather than being assumed here, because a QML client cannot
  // call getpagesize().
  property real processPageSize: 4096

  // How many rows each list shows. Ten is what was asked for and what fits
  // the popup without turning it into a scrolling process viewer.
  readonly property int processListLength: 10

  function applyProcesses(text) {
    var rows = Parsers.parseProcessTable(text)
    var now = Date.now()
    var dt = previousProcessesAt > 0 ? now - previousProcessesAt : 0

    // A sweep that came back empty is a failed or truncated read, not a
    // machine with no processes. Keep the previous lists and the baseline
    // rather than blanking a panel the user is looking at.
    if (rows.length === 0) {
      processesRevision += 1
      revision += 1
      updated("processes")
      return
    }

    var withCpu = Parsers.processCpuPercents(previousProcessTicks, rows, dt)

    // Sorted twice over the same rows: the two lists answer different
    // questions and a process is routinely near the top of one and absent
    // from the other.
    topCpuProcesses = decorate(Parsers.topProcesses(withCpu, "cpuPercent", processListLength))
    topMemoryProcesses = decorate(Parsers.topProcesses(withCpu, "rssPages", processListLength))

    previousProcessTicks = Parsers.processTicksByPid(rows)
    previousProcessesAt = now
    processesRevision += 1
    revision += 1
    updated("processes")
  }

  // Pages become bytes here, at the one point that knows the page size.
  function decorate(rows) {
    var out = []
    for (var i = 0; i < rows.length; i++) {
      out.push({
        pid: rows[i].pid,
        comm: rows[i].comm,
        cpuPercent: rows[i].cpuPercent,
        rssBytes: rows[i].rssPages * processPageSize
      })
    }
    return out
  }

  // The baseline is only valid across a continuous run of sweeps. When the
  // lists are collapsed the sweeps stop, so the next one would compute its
  // delta against ticks from minutes ago and read as a huge, wrong spike.
  // Dropping the baseline costs one sweep with no CPU reading, which is the
  // honest state to be in.
  function resetProcessBaseline() {
    previousProcessTicks = ({})
    previousProcessesAt = 0
  }

  // Collapsing (or closing the popup) ends the run of sweeps, so the baseline
  // goes with it. Re-expanding then starts a fresh run rather than differencing
  // against a stale one.
  onProcessesExpandedChanged: if (!processesExpanded) resetProcessBaseline()
  onPopupOpenChanged: if (!popupOpen) resetProcessBaseline()

  // ---- Ring sizing -------------------------------------------------------

  function rebuildRings() {
    var size = config.historyLength
    cpuHistory = Engine.makeRing(size)
    memoryHistory = Engine.makeRing(size)
    swapHistory = Engine.makeRing(size)
    networkRxHistory = Engine.makeRing(size)
    networkTxHistory = Engine.makeRing(size)
    diskReadHistory = Engine.makeRing(size)
    diskWriteHistory = Engine.makeRing(size)
    gpuHistory = Engine.makeRing(size)
    storageHistory = Engine.makeRing(size)
    vramHistory = Engine.makeRing(size)
    temperatureHistory = Engine.makeRing(size)
    gpuTemperatureHistory = Engine.makeRing(size)
  }

  onConfigChanged: rebuildRings()
}

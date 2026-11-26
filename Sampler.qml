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
  property int cpupowerRevision: 0
  property int gpupowerRevision: 0

  // The repaint dependency for one metric. A view that draws a single metric
  // states this rather than `revision`, so it is invalidated only by its own
  // samples.
  function revisionOf(id) {
    // A further card's metric (vram2) shares its base metric's counter.
    if (Config.gpuIndex(id) > 0) id = Config.baseMetricId(id)
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
    if (id === "cpupower") return cpupowerRevision
    if (id === "gpupower") return gpupowerRevision
    return revision
  }

  signal updated(string metricId)

  // Pinned to the bar. Governs what the strip draws.
  function enabled(id) {
    return config.metrics.indexOf(id) >= 0
  }

  // The ids a recording in progress is logging; empty when nothing records.
  property var recording: []

  // Worth sampling right now. A metric that is not on the bar still has a
  // section in the popup, and that section is useless without live data — so
  // while the popup is open everything is sampled, not just the pinned set.
  // Closed, only the pinned metrics cost anything -- plus whatever is being
  // recorded, since a log with the popup shut is the whole point of one.
  function sampling(id) {
    return popupOpen || enabled(id) || recording.indexOf(id) >= 0
  }

  // The same for one card's reading: "vram" on card 1 is the id "vram2".
  function samplingGpu(base, index) {
    return sampling(Config.gpuMetricId(base, index))
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
  // One 60-slot history per logical core, so the popup can draw a mini graph
  // beside each percentage the way btop does. The array is rebuilt only when
  // the core count changes (SMT toggled, a CPU hotplugged); otherwise the
  // rings are mutated in place and the consumers see it through their
  // revision dependency, exactly like the aggregate ring.
  property var cpuCoreHistory: []
  property var previousCpuAggregate: null
  property var previousCpuCores: []
  property var loadAverage: ({ one: NaN, five: NaN, fifteen: NaN })

  // CPU identity for the popup header. The model is read once at startup
  // (discovery, not the sampling timer); the frequency is popup-only, like the
  // load average -- neither is on the strip, so neither costs anything while
  // the popup is shut.
  property string cpuModel: ""
  property real cpuFrequencyKhz: NaN

  function applyCpuModel(text) {
    cpuModel = Parsers.parseCpuModel(text)
  }

  function applyCpuFrequency(text) {
    // cpufreq reports kilohertz. Zero is a missing driver, not a frequency, so
    // it is dropped to NaN and the header shows a dash rather than "0.0 GHz".
    var khz = Parsers.parseFirstNumber(text)
    cpuFrequencyKhz = isFinite(khz) && khz > 0 ? khz : NaN
  }

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

    // Per-core history, one ring each. Grows or shrinks with the core list so
    // a machine whose SMT is toggled ends up with exactly as many graphs as
    // it has cores, and every graph keeps its place across a resize.
    if (cpuCoreHistory.length !== cores.length) {
      var coreRings = []
      for (var r = 0; r < cores.length; r++) coreRings.push(Engine.makeRing(config.historyLength))
      cpuCoreHistory = coreRings
    }
    for (var c = 0; c < cores.length; c++) Engine.ringPush(cpuCoreHistory[c], cores[c])

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
                          freeKB: 0, cachedKB: 0, buffersKB: 0,
                          swapTotalKB: 0, swapUsedKB: 0 })
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
  // Cumulative bytes since the interface came up, not a rate: btop shows the
  // running totals beside the speeds, and they answer "how much has gone
  // through" rather than "how fast right now".
  property real networkTotalRx: NaN
  property real networkTotalTx: NaN
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
      networkTotalRx = NaN
      networkTotalTx = NaN
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
    // The absolute counters the rates are differenced from. They are the
    // interface's own since-boot totals, so no baseline is involved.
    networkTotalRx = current.rxBytes
    networkTotalTx = current.txBytes
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

      // Utilisation: the time the device had I/O in flight as a share of the
      // wall-clock interval. io_ticks is already milliseconds, so the delta
      // over dt (also ms) is the percentage. Clamped because the kernel's
      // accounting can carry a tick over the sample boundary.
      var busy = NaN
      if (previous && dt > 0
          && typeof previous.ioTicks === "number" && typeof current.ioTicks === "number"
          && current.ioTicks >= previous.ioTicks) {
        busy = Math.max(0, Math.min(100, (current.ioTicks - previous.ioTicks) / dt * 100))
      }

      perDevice[name] = {
        read: read === null ? NaN : read,
        write: write === null ? NaN : write,
        busy: busy
      }
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

  // Every card discovery found, main card first: the one gpu.card names,
  // otherwise the one with the most VRAM -- on a machine with an integrated
  // and a discrete GPU, the discrete one. Each entry carries its own readings
  // and rings: { card, slot, pciId, name, label, devicePath, temperaturePath, powerPath,
  // usage, vramUsed, vramTotal, temperature, power, usageHistory, vramHistory,
  // temperatureHistory, powerHistory }. The fields are mutated in place, like
  // the rings, so views read them under their metric's revision counter.
  //
  // The scalars below are the main card's, for the bar, which draws one
  // gauge per metric: its rings are the main card's rings, not copies.
  property var gpus: []
  // "Radeon 610M, card0 (0d:00.0)" per entry, in order, for the analysis prompt.
  property var gpuLabels: []
  // Raised once discovery has run, even when it found nothing: a recording
  // waits for it, so its header has a column group for every card.
  property bool gpusResolved: false

  property string gpuCard: ""          // the main card, e.g. "card1"
  property real gpuUsage: NaN
  property var gpuHistory: Engine.makeRing(60)
  property real gpuVramUsed: NaN
  property real gpuVramTotal: NaN
  property var vramHistory: Engine.makeRing(60)

  readonly property real vramPercent: (gpuVramTotal > 0 && !isNaN(gpuVramUsed))
    ? (gpuVramUsed * 100 / gpuVramTotal)
    : NaN

  function gpuVramPercent(gpu) {
    return gpu && gpu.vramTotal > 0 && !isNaN(gpu.vramUsed) ? gpu.vramUsed * 100 / gpu.vramTotal : NaN
  }

  // found: [{ card, slot, pciId, devicePath, temperaturePath, powerPath }],
  // main card first. The same list again keeps the history; a different one
  // starts every card's rings afresh.
  function setGpus(found) {
    var idents = found.map(g => g.card + (g.slot ? " (" + g.slot.replace(/^0000:/, "") + ")" : ""))
    var same = idents.length === gpus.length && gpus.every((g, i) => g.ident === idents[i]
      && g.temperaturePath === found[i].temperaturePath && g.powerPath === found[i].powerPath)
    if (same) {
      gpusResolved = true
      return
    }
    var size = config.historyLength
    gpus = found.map((g, i) => ({
      card: g.card, slot: g.slot, pciId: g.pciId, ident: idents[i],
      name: "", label: idents[i], devicePath: g.devicePath,
      temperaturePath: g.temperaturePath, powerPath: g.powerPath,
      usage: NaN, vramUsed: NaN, vramTotal: NaN, temperature: NaN, power: NaN,
      usageHistory: Engine.makeRing(size), vramHistory: Engine.makeRing(size),
      temperatureHistory: Engine.makeRing(size), powerHistory: Engine.makeRing(size)
    }))
    gpuLabels = idents
    gpuUsage = NaN; gpuVramUsed = NaN; gpuVramTotal = NaN; gpuTemperature = NaN; gpuPower = NaN
    aliasMainGpu()
    // Last, so a recording waiting on it finds the labels already in place.
    gpusResolved = true
  }

  // Marketing names by PCI id, from the system's pci.ids: { "1002:73df":
  // "Radeon RX 6700/6700 XT/6750 XT / 6800M/6850M XT" }. A card with no entry
  // keeps its DRM name.
  function applyGpuNames(names) {
    for (var i = 0; i < gpus.length; i++) {
      var name = names[gpus[i].pciId] || ""
      gpus[i].name = name
      gpus[i].label = name !== "" ? name : gpus[i].ident
    }
    gpuLabels = gpus.map(g => g.name !== "" ? g.name + ", " + g.ident : g.ident)
    gpus = gpus.slice()
  }

  function aliasMainGpu() {
    var main = gpus.length > 0 ? gpus[0] : null
    gpuCard = main ? main.card : ""
    gpuHistory = main ? main.usageHistory : Engine.makeRing(config.historyLength)
    vramHistory = main ? main.vramHistory : Engine.makeRing(config.historyLength)
    gpuTemperatureHistory = main ? main.temperatureHistory : Engine.makeRing(config.historyLength)
    gpuPowerHistory = main ? main.powerHistory : Engine.makeRing(config.historyLength)
    hasGpuPowerSensor = gpus.some(g => g.powerPath !== "")
  }

  function applyGpuBusy(index, text) {
    var gpu = gpus[index]
    if (!gpu) return
    var value = Parsers.parseFirstNumber(text)
    gpu.usage = value
    Engine.ringPush(gpu.usageHistory, value)
    if (index === 0) gpuUsage = value
    gpuRevision += 1
    revision += 1
    updated("gpu")
  }

  function applyVramUsed(index, text) {
    var gpu = gpus[index]
    if (!gpu) return
    gpu.vramUsed = Parsers.parseFirstNumber(text)
    if (index === 0) gpuVramUsed = gpu.vramUsed
  }

  // Total arrives after used in the same tick, so this is the point at which
  // the pair is consistent enough to record.
  function applyVramTotal(index, text, record) {
    var gpu = gpus[index]
    if (!gpu) return
    gpu.vramTotal = Parsers.parseFirstNumber(text)
    if (index === 0) gpuVramTotal = gpu.vramTotal
    if (!record) return
    Engine.ringPush(gpu.vramHistory, gpuVramPercent(gpu))
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

  function applyGpuTemperature(index, text) {
    var gpu = gpus[index]
    if (!gpu) return
    var celsius = Parsers.parseHwmonMillidegrees(text)
    gpu.temperature = celsius
    Engine.ringPush(gpu.temperatureHistory, celsius)
    if (index === 0) gpuTemperature = celsius
    gputempRevision += 1
    revision += 1
    updated("gputemp")
  }

  // ---- Power -------------------------------------------------------------
  //
  // Two sources, read very differently. The CPU package reports a cumulative
  // energy counter (RAPL energy_uj), so its power is a delta over time, like a
  // byte counter. The GPU reports power directly (amdgpu's power1_average, in
  // microwatts). RAPL is root-only by default, so the CPU half may simply be
  // unreadable; `cpuPowerReadable` lets the popup say why rather than show a
  // bare dash.
  //
  // Two metrics, not one total: the question is which device is drawing, and
  // a sum hides exactly that. Each pins, plots and logs on its own.

  property real cpuPower: NaN
  property real gpuPower: NaN
  property bool cpuPowerReadable: true
  property real energyRangeUj: NaN
  property var cpuPowerHistory: Engine.makeRing(60)
  property var gpuPowerHistory: Engine.makeRing(60)
  property real previousEnergyUj: NaN
  property real previousEnergyAt: 0
  // Set by discovery, so the GPU section can be hidden on a machine without
  // the sensor rather than flashing in on its first reading. True when any
  // card has one.
  property bool hasGpuPowerSensor: false

  function applyCpuEnergy(text) {
    var uj = Parsers.parseFirstNumber(text)
    var now = Date.now()
    var watts = Engine.powerFromEnergy(previousEnergyUj, uj, now - previousEnergyAt, energyRangeUj)
    cpuPower = watts === null ? NaN : watts
    previousEnergyUj = uj
    previousEnergyAt = now
    cpuPowerReadable = true
    recordCpuPower()
  }

  // A refused read also drops the baseline: once access is granted, the first
  // good reading must not be differenced against one from before.
  function cpuEnergyUnreadable() {
    cpuPower = NaN
    previousEnergyUj = NaN
    cpuPowerReadable = false
    recordCpuPower()
  }

  function applyGpuPower(index, text) {
    var gpu = gpus[index]
    if (!gpu) return
    var microwatts = Parsers.parseFirstNumber(text)
    gpu.power = isFinite(microwatts) && microwatts >= 0 ? microwatts / 1e6 : NaN
    Engine.ringPush(gpu.powerHistory, gpu.power)
    if (index === 0) gpuPower = gpu.power
    gpupowerRevision += 1
    revision += 1
    updated("gpupower")
  }

  function recordCpuPower() {
    Engine.ringPush(cpuPowerHistory, cpuPower)
    cpupowerRevision += 1
    revision += 1
    updated("cpupower")
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

  // The size the live rings were built at. Rebuilding is what makes a config
  // change cost the history, so it must happen only when the size is really
  // what moved -- not when an unrelated key did.
  property int ringSize: 60

  function rebuildRings() {
    var size = config.historyLength
    ringSize = size
    cpuHistory = Engine.makeRing(size)
    cpuCoreHistory = []
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
    cpuPowerHistory = Engine.makeRing(size)
    gpuPowerHistory = Engine.makeRing(size)
    for (var g = 0; g < gpus.length; g++) {
      gpus[g].usageHistory = Engine.makeRing(size)
      gpus[g].vramHistory = Engine.makeRing(size)
      gpus[g].temperatureHistory = Engine.makeRing(size)
      gpus[g].powerHistory = Engine.makeRing(size)
    }
    aliasMainGpu()
  }

  // A card whose power file turned out not to exist after all: dropped from
  // the power section. Reassigned so the views see the list change.
  function gpuPowerUnavailable(index) {
    if (!gpus[index] || gpus[index].powerPath === "") return
    gpus[index].powerPath = ""
    gpus = gpus.slice()
    hasGpuPowerSensor = gpus.some(g => g.powerPath !== "")
  }

  // Guarded on the size, not on the config object. Every write to `settings`
  // yields a fresh config, so an unguarded rebuild threw away every ring
  // whenever any key moved -- toggling a sparkline off emptied the popup's
  // charts, which have nothing to do with it.
  onConfigChanged: if (config.historyLength !== ringSize) rebuildRings()
}

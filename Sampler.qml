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

  // Bumped on every committed sample. Canvas does not repaint on binding
  // changes, so views hang their requestPaint() off this.
  property int revision: 0

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

  property real cpuUsage: NaN
  property var cpuCores: []           // current percent per logical core
  property var cpuHistory: Engine.makeRing(60)
  property var previousCpuAggregate: null
  property var previousCpuCores: []
  property var loadAverage: ({ one: NaN, five: NaN, fifteen: NaN })

  function applyProcStat(text) {
    var parsed = Parsers.parseProcStat(text)
    if (!parsed.aggregate) return

    var usage = Engine.cpuBusyPercent(previousCpuAggregate, parsed.aggregate)
    // A null derive means there is no measurable interval yet (first sample,
    // or a counter reset). Pushing NaN keeps the plot honest instead of
    // drawing a dip to zero that never happened.
    Engine.ringPush(cpuHistory, usage === null ? NaN : usage)
    cpuUsage = usage === null ? NaN : usage
    previousCpuAggregate = parsed.aggregate

    // Per-core is parsed on every tick, popup open or not: it rides along in
    // the same read the aggregate already needs, and gating it would break
    // delta continuity so the grid would be blank each time the popup opens.
    var cores = []
    for (var i = 0; i < parsed.cores.length; i++) {
      var perCore = Engine.cpuBusyPercent(previousCpuCores[i], parsed.cores[i])
      cores.push(perCore === null ? NaN : perCore)
    }
    cpuCores = cores
    previousCpuCores = parsed.cores

    revision += 1
    lastSampleAt = Date.now()
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
    revision += 1
    updated("storage")
  }

  // ---- Uptime --------------------------------------------------------------

  property real uptimeSeconds: NaN

  function applyUptime(text) {
    uptimeSeconds = Parsers.parseUptimeSeconds(text)
    revision += 1
  }

  // Seconds since the last successful sample, so the popup can say how fresh
  // its numbers are rather than leaving stale ones looking live.
  property real lastSampleAt: 0
  property int freshnessTick: 0
  readonly property real secondsSinceSample: {
    void freshnessTick
    if (lastSampleAt <= 0) return NaN
    return Math.max(0, (Date.now() - lastSampleAt) / 1000)
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
    revision += 1
    updated("gpu")
  }

  function recordVram() {
    Engine.ringPush(vramHistory, vramPercent)
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
    revision += 1
    updated("cputemp")
  }

  function applyGpuTemperature(text) {
    var celsius = Parsers.parseHwmonMillidegrees(text)
    gpuTemperature = celsius
    Engine.ringPush(gpuTemperatureHistory, celsius)
    revision += 1
    updated("gputemp")
  }

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

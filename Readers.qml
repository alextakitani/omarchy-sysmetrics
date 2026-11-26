import QtQuick
import Quickshell
import Quickshell.Io
import "js/parsers.js" as Parsers

// All file I/O for the strip, plus the runtime discovery that finds the GPU
// and the temperature sensor.
//
// Discovery matters because neither is addressable by a fixed path: DRM card
// numbers are not stable across reboots and /sys/class/drm also holds
// connector entries (card1-DP-1, card1-HDMI-A-1), while hwmon numbering shifts
// with probe order. Both are therefore resolved by identity — the GPU by its
// uevent DRIVER, the sensor by its hwmon name — never by index.
Item {
  id: readers

  property QtObject sampler: null
  readonly property bool ready: sampler !== null

  // ---- Always-on readers -------------------------------------------------

  readonly property bool wantCpu: ready && sampler.sampling("cpu")
  readonly property bool wantMemory: ready && sampler.sampling("memory")
  readonly property bool wantNetwork: ready && sampler.sampling("network")
  readonly property bool wantDisk: ready && sampler.sampling("disk")
  readonly property bool wantStorage: ready && sampler.sampling("storage")
  readonly property bool wantTemperature: ready && sampler.sampling("cputemp")
  readonly property bool wantCpuPower: ready && sampler.sampling("cpupower")
  // Not a `sampling()` metric: the process lists cannot be pinned to the bar,
  // so they have no `metrics` entry to consult. They are gated on their own
  // sections being expanded instead, which is stricter than popupOpen.
  readonly property bool wantProcesses: ready && sampler.popupOpen && sampler.processesExpanded

  // Sampling is rate limited because sampleAll() is reachable from outside
  // the timer: an IPC client can call takitani.sysmetrics.refresh in a loop,
  // and a middle click is a second unthrottled path. Every reader now costs a
  // subprocess, so an unbounded call rate is fork/exec pressure on the shared
  // shell rather than just redundant reads. Callers that arrive too early are
  // dropped rather than queued -- the next scheduled tick has the same data.
  // Half the fastest interval config will accept (clamped to >= 500ms in
  // config.js), so this never throttles legitimate sampling -- only the
  // external callers, which have no cadence of their own.
  property double lastSampleAt: 0
  readonly property int minSampleIntervalMs: 250

  function sampleAll() {
    if (!ready) return
    var now = Date.now()
    if (now - lastSampleAt < minSampleIntervalMs) return
    lastSampleAt = now
    if (wantCpu) statFile.reload()
    if (wantMemory) meminfoFile.reload()
    if (wantNetwork) {
      // The default route is re-read on a slower cadence than the counters:
      // it changes rarely, and parsing it every tick is wasted work.
      if (routeTicks <= 0) { routeFile.reload(); routeTicks = 15 }
      routeTicks -= 1
      netDevFile.reload()
    }
    if (wantDisk) diskstatsFile.reload()
    for (var g = 0; g < gpuReaders.count; g++) gpuReaders.itemAt(g).sample()
    if (wantTemperature && temperatureInputPath !== "") temperatureFile.reload()

    // Capacity is the one reading that needs a subprocess: it comes from
    // statvfs, which QML does not expose and procfs does not carry. df is
    // cheap (~2ms) but disk usage moves over minutes, so it runs on its own
    // slow cadence rather than on every tick.
    if (wantStorage) {
      // A hung df is the failure to design for here, not a slow one. statfs()
      // blocks uninterruptibly on a wedged NFS or FUSE mount, and the
      // overlap guard below would then turn one stuck child into permanent
      // silence: running never goes false, so every later cadence is skipped
      // and the reading stays frozen for the life of the session. So an
      // overdue run is killed and the next cadence is allowed to try again.
      if (dfProcess.running) {
        dfWaited += 1
        if (dfWaited > dfMaxWaits) {
          dfProcess.running = false      // SIGTERM; collector yields nothing
          dfWaited = 0
        }
      } else if (storageTicks <= 0) {
        dfWaited = 0
        dfProcess.running = true
        storageTicks = 15
      }
      storageTicks -= 1
    }
    if (wantCpuPower) {
      energyRequested = true
      energyFile.reload()
    }

    // Popup-only detail: level readings with no history, so sampling them
    // lazily costs nothing and they are correct on the popup's first tick.
    // Uptime belongs here too — it is drawn only in the popup header, so
    // reading it every tick with the popup shut was a file read per interval,
    // all day, for a number nobody was looking at.
    if (ready && sampler.popupOpen) {
      uptimeFile.reload()
      if (wantCpu) {
        loadavgFile.reload()
        cpuFrequencyFile.reload()
      }
      for (var v = 0; v < gpuReaders.count; v++) {
        var reader = gpuReaders.itemAt(v)
        if (reader.wantBusy && !reader.wantVram) reader.readVram()
      }
    }

    // The dearest read here by some margin: a sweep of every /proc/<pid>/stat
    // on the machine. It runs on the sampling tick rather than a slow cadence
    // of its own, because its CPU column is a delta between consecutive
    // sweeps -- stretching the gap would report an average over that whole
    // gap instead of what is busy now. What keeps it cheap is that it only
    // runs at all while a process list is actually expanded.
    //
    // Same wedge guard as df, for the same reason: a stuck child must not
    // turn into permanent silence by leaving `running` true forever.
    if (wantProcesses) {
      if (processesProcess.running) {
        processesWaited += 1
        if (processesWaited > processesMaxWaits) {
          processesProcess.running = false   // SIGTERM; collector yields nothing
          processesWaited = 0
        }
      } else {
        processesWaited = 0
        processesProcess.running = true
      }
    }
  }

  property int routeTicks: 0
  property bool energyRequested: false
  property int storageTicks: 0

  // Ticks the current df run has been outstanding, and the ceiling past which
  // it is presumed wedged. df on healthy mounts returns in ~2ms; this is
  // three sampling ticks, so it only fires on a genuinely stuck statfs.
  property int dfWaited: 0
  readonly property int dfMaxWaits: 3

  // Same guard for the process sweep. It reads only procfs, which does not
  // block the way a wedged NFS statfs does, but a fork that never returns
  // would freeze the lists just as thoroughly.
  property int processesWaited: 0
  readonly property int processesMaxWaits: 3

  // Bound a FileView read that the kernel already bounds for us.
  //
  // This is the WEAK form of the ceiling and it is deliberately only used
  // where it is sufficient. FileView completes its read in full before
  // onLoaded fires, so a check written here -- on text(), or on
  // data().byteLength -- runs after the allocation it is meant to prevent.
  // Measured against an 80 MB file on a real quickshell: RSS at the first
  // line of onLoaded is already +225 MB, and returning "" reclaims none of
  // it. FileView exposes no size limit, so for a file whose size something
  // outside this plugin decides, the ceiling cannot live here at all -- it
  // has to move to the producer. Those readers use BoundedReader instead.
  //
  // What remains here are the files the kernel itself bounds to a single
  // page: the sysfs one-value reads, /proc/uptime, /proc/loadavg, and the
  // hwmon name probe. For those this check is a backstop against a surprise,
  // not the thing standing between the shell and a flood.
  function boundedText(view) {
    var buffer = view.data()
    if (!buffer) return ""
    if (buffer.byteLength >= Parsers.PROC_MAX_BYTES) return ""
    return view.text()
  }

  // Exposed so the runtime suite can exercise boundedText against a real
  // FileView rather than a stand-in. It is a kernel-bounded reader, which is
  // the only kind still on FileView.
  readonly property alias uptimeFileView: uptimeFile

  // /proc/stat, /proc/net/dev, /proc/diskstats, /proc/net/route and
  // /proc/meminfo all read through BoundedReader rather than FileView: their
  // row counts are decided outside this plugin (interfaces and veth pairs
  // appear, block and loop devices appear, routes are added) and every one of
  // them runs on the sampling timer inside the shared shell. FileView would
  // materialise the whole file before we could reject it.
  BoundedReader {
    id: statFile
    path: "/proc/stat"
    maxBytes: Parsers.PROC_MAX_BYTES
    onRead: text => { if (readers.ready) readers.sampler.applyProcStat(text) }
  }

  FileView {
    id: uptimeFile
    path: "/proc/uptime"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyUptime(readers.boundedText(this))
  }

  // The CPU's name, for the popup header. Read once at startup like the hwmon
  // name probe: it cannot change while the machine is up. /proc/cpuinfo is not
  // kernel-bounded to a page, so the value goes through boundedText -- a
  // machine whose cpuinfo ran past the ceiling shows no model rather than
  // allocating it.
  FileView {
    id: cpuInfoFile
    path: "/proc/cpuinfo"
    watchChanges: false
    printErrors: false
    blockLoading: true
    Component.onCompleted: if (readers.ready) readers.sampler.applyCpuModel(readers.boundedText(this))
  }

  // The CPU frequency, for the popup header. cpufreq reports one value per
  // policy; cpu0 is representative on x86, and its recent-window average
  // (cpuinfo_avg_freq) is steadier than the instantaneous scaling_cur_freq, so
  // it is preferred with the latter as a fallback on older kernels. Popup-only:
  // it is reloaded with the other detail readings, never on the strip's tick.
  FileView {
    id: cpuFrequencyFile
    path: "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_avg_freq"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyCpuFrequency(readers.boundedText(this))
    onLoadFailed: {
      // One fallback only: the guard keeps a machine with no cpufreq at all
      // from retrying the same alternate path forever.
      if (cpuFrequencyFile.path.endsWith("/scaling_cur_freq")) return
      cpuFrequencyFile.path = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
    }
  }

  Process {
    id: dfProcess
    // -x excludes the pseudo-filesystems that would otherwise dominate the
    // list; the parser drops anything under a gibibyte as a second guard.
    //
    // The mount table is not ours to trust: any user can mount FUSE
    // filesystems in a loop, with mount points as long as they like, and this
    // runs on a timer inside the shared shell. So the pipe itself is capped at
    // 64 KiB by head rather than letting an unbounded df fill a QML string --
    // the collector never sees more than the ceiling. Output that reaches the
    // ceiling is treated as truncated and discarded whole by the parser; a
    // capacity reading is worth less than a torn row parsed as fact.
    command: ["sh", "-c",
              "df -B1 --output=target,size,used,avail" +
              " -x tmpfs -x devtmpfs -x squashfs -x overlay | head -c 65536"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (readers.ready) readers.sampler.applyDf(text)
    }
  }

  // The whole process table, reduced to one short row per process before it
  // ever reaches the shell.
  //
  // There is no FileView path to this: /proc/<pid>/stat is one file per
  // process, and QML cannot glob. Reading them individually would be hundreds
  // of FileViews churning as pids come and go. So awk does the sweep, and --
  // as with df -- the reduction happens in the producer rather than after the
  // payload exists: each ~300-byte stat line becomes ~30 bytes, which is what
  // keeps a 500-process machine at ~13 KB rather than 150 KB.
  //
  // Fields, from proc(5): 14 utime, 15 stime, 24 rss (in pages). They are
  // indexed off the closing parenthesis rather than counted from the start of
  // the line, because field 2 is `comm` -- an arbitrary 16-byte string that
  // may itself contain spaces and parentheses, which would shift every
  // positional index after it. Scanning for the LAST ")" is the documented way
  // to find where the fixed-width fields resume.
  //
  // comm is then stripped of anything outside printable ASCII: it is a string
  // the kernel accepted, not one we chose, and it ends up rendered as a label.
  //
  // Exposed so the recorder runs the same sweep on its own, slower cadence.
  readonly property string processSweepScript:
              "getconf PAGESIZE; " +
              "(head -qn1 /proc/[0-9]*/stat 2>/dev/null | awk '{" +
              "line=$0; cp=0;" +
              "for(i=length(line);i>0;i--){if(substr(line,i,1)==\")\"){cp=i;break}}" +
              "if(cp==0)next;" +
              "op=index(line,\"(\"); if(op<2)next;" +
              "pid=substr(line,1,op-2);" +
              "comm=substr(line,op+1,cp-op-1);" +
              "rest=substr(line,cp+2);" +
              "n=split(rest,f,\" \"); if(n<22)next;" +
              "gsub(/[^ -~]/,\"?\",comm);" +
              "print pid, (f[12]+f[13]), f[22], comm" +
              // head walks the files, not awk: a pid that exits between the
              // glob expanding and its file being opened is FATAL to gawk,
              // which then dropped every pid after it -- routinely, since this
              // plugin's own `head` readers come and go on every tick. head
              // reports the missing file and moves on. -n1 keeps only each
              // file's first line, as FNR==1 did, so a comm with an embedded
              // newline cannot spill a forged second row into the output.
              "}' || true) | head -c 262144"

  Process {
    id: processesProcess
    command: ["sh", "-c", readers.processSweepScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!readers.ready) return
        // The page size rides in on the first line, so the sampler can turn
        // pages into bytes without assuming 4 KiB.
        var body = text
        var newline = body.indexOf("\n")
        if (newline > 0) {
          var pageSize = Number(body.slice(0, newline))
          if (isFinite(pageSize) && pageSize > 0) readers.sampler.processPageSize = pageSize
          body = body.slice(newline + 1)
        }
        readers.sampler.applyProcesses(body)
      }
    }
  }

  BoundedReader {
    id: meminfoFile
    path: "/proc/meminfo"
    maxBytes: Parsers.PROC_MAX_BYTES
    onRead: text => { if (readers.ready) readers.sampler.applyMeminfo(text) }
  }

  BoundedReader {
    id: routeFile
    path: "/proc/net/route"
    maxBytes: Parsers.PROC_MAX_BYTES
    onRead: text => {
      if (!readers.ready) return
      var resolved = readers.sampler.resolveInterface(text)
      if (resolved !== readers.sampler.networkInterface) {
        // Switching interfaces invalidates the byte baseline.
        readers.sampler.networkInterface = resolved
        readers.sampler.previousNetwork = null
        readers.sampler.previousNetworkAt = 0
      }
    }
  }

  BoundedReader {
    id: netDevFile
    path: "/proc/net/dev"
    maxBytes: Parsers.PROC_MAX_BYTES
    onRead: text => { if (readers.ready) readers.sampler.applyNetDev(text) }
  }

  BoundedReader {
    id: diskstatsFile
    path: "/proc/diskstats"
    maxBytes: Parsers.PROC_MAX_BYTES
    onRead: text => { if (readers.ready) readers.sampler.applyDiskstats(text) }
  }

  FileView {
    id: loadavgFile
    path: "/proc/loadavg"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.loadAverage = Parsers.parseLoadavg(readers.boundedText(this))
  }

  // ---- Hardware discovery ------------------------------------------------
  // Both the GPU and the temperature sensor are found by identity rather than
  // by index, because neither index is stable: DRM card numbers change across
  // reboots (and /sys/class/drm also holds connector entries such as
  // card1-DP-1), while hwmon numbering follows probe order.
  //
  // Each probe is a fixed set of FileViews resolved once at startup with
  // blockLoading, so discovery costs one synchronous sweep and nothing per
  // tick. A missing path is a normal miss, not an error.

  // Every card is collected, not just the first: a desktop with an APU and a
  // discrete card has two amdgpu cards, and taking whichever came first read
  // the idle integrated one. Each card is later joined to its own hwmon by PCI
  // slot, because both hwmons are named "amdgpu" and a name cannot tell them
  // apart.
  property var gpuCardsFound: ({})     // "card1" -> { driver, slot, vramTotal }
  property var hwmonSlots: ({})        // "hwmon1" -> "0000:03:00.0"

  // Both probes are synchronous sweeps of fixed size, so the list is built
  // once, when the last slot of either has reported.
  property int probesPending: 8 + 16

  function probeDone() {
    probesPending -= 1
    if (probesPending === 0) resolveGpus()
  }

  Item {
    id: gpuProbe
    visible: false

    Repeater {
      model: 8        // unconditional: discovery runs once, not per popup open
      delegate: Item {
        id: gpuSlot
        required property int index

        FileView {
          id: gpuVramTotal
          path: "/sys/class/drm/card" + gpuSlot.index + "/device/mem_info_vram_total"
          watchChanges: false
          printErrors: false
          blockLoading: true
        }

        FileView {
          id: gpuUevent
          path: "/sys/class/drm/card" + gpuSlot.index + "/device/uevent"
          watchChanges: false
          printErrors: false
          blockLoading: true

          Component.onCompleted: {
            if (readers.ready) {
              var fields = Parsers.parseUevent(readers.boundedText(gpuUevent))
              var driver = fields.DRIVER ? String(fields.DRIVER) : ""
              if (driver !== "") {
                var map = {}
                for (var key in readers.gpuCardsFound) map[key] = readers.gpuCardsFound[key]
                map["card" + gpuSlot.index] = {
                  driver: driver,
                  slot: readers.pciSlot(fields.PCI_SLOT_NAME),
                  pciId: /^[0-9a-f]{4}:[0-9a-f]{4}$/i.test(String(fields.PCI_ID || ""))
                    ? String(fields.PCI_ID).toLowerCase() : "",
                  vramTotal: Parsers.parseFirstNumber(readers.boundedText(gpuVramTotal))
                }
                readers.gpuCardsFound = map
              }
            }
            readers.probeDone()
          }
        }
      }
    }
  }

  readonly property var gpuDrivers: ["amdgpu", "i915", "xe", "nouveau", "nvidia", "radeon"]

  // A PCI address ("0000:03:00.0") in exactly that shape, or nothing: it is
  // compared and shown, never used as a path.
  function pciSlot(value) {
    var slot = String(value || "")
    return /^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/i.test(slot) ? slot : ""
  }

  // gpu.card names the main card instead of letting VRAM size decide. It
  // becomes a path segment, so it is accepted only in exactly the shape the
  // kernel uses -- "card" followed by digits. Anything else is ignored in
  // favour of discovery rather than concatenated into /sys/class/drm/<...>/device/.
  readonly property string configuredGpuCard: {
    if (!ready) return ""
    var configured = String(sampler.config.gpu.card)
    return /^card\d{1,3}$/.test(configured) ? configured : ""
  }

  readonly property string configuredGpuSensor: ready ? String(sampler.config.gputemp.sensor) : "auto"

  onConfiguredGpuCardChanged: resolveGpus()
  onConfiguredGpuSensorChanged: resolveGpus()

  // Builds the card list for the sampler: main card first, the rest in PCI
  // order, each with the temperature and power files of its own hwmon.
  function resolveGpus() {
    if (!ready || probesPending > 0) return
    var found = gpuCardsFound
    var cards = Object.keys(found).filter(c => gpuDrivers.indexOf(found[c].driver) >= 0 || c === configuredGpuCard)
    cards.sort((a, b) => (found[a].slot < found[b].slot ? -1 : found[a].slot > found[b].slot ? 1 : 0)
                         || Number(a.slice(4)) - Number(b.slice(4)))
    // The main card: the configured one, else the most VRAM (the discrete
    // card beside an APU's carve-out), PCI order breaking ties and covering
    // drivers that report no VRAM at all.
    var main = cards.indexOf(configuredGpuCard)
    if (main < 0) {
      main = 0
      for (var i = 1; i < cards.length; i++)
        if ((found[cards[i]].vramTotal || 0) > (found[cards[main]].vramTotal || 0)) main = i
    }
    if (cards.length > 0) cards.unshift(cards.splice(main, 1)[0])

    var used = {}
    var list = cards.map(card => {
      var hwmon = gpuHwmon(found[card], used)
      var name = hwmon ? hwmonNames[hwmon] : ""
      return {
        card: card,
        slot: found[card].slot,
        pciId: found[card].pciId,
        devicePath: "/sys/class/drm/" + card + "/device/",
        // amdgpu/nouveau expose the die reading as temp1_input, labelled
        // "edge" on amdgpu; nvidia's is surfaced the same way by its driver.
        temperaturePath: hwmon ? "/sys/class/hwmon/" + hwmon + "/temp1_input" : "",
        powerPath: hwmon && (name === "amdgpu" || name === "nouveau")
          ? "/sys/class/hwmon/" + hwmon + "/power1_average" : ""
      }
    })
    // A configured gputemp.sensor names the hwmon directly and wins for the
    // main card, which is what the README documents.
    if (list.length > 0 && configuredGpuSensor !== "auto") {
      for (var key in hwmonNames) {
        if (hwmonNames[key] === configuredGpuSensor) {
          list[0].temperaturePath = "/sys/class/hwmon/" + key + "/temp1_input"
          break
        }
      }
    }
    sampler.setGpus(list)
    var ids = list.map(g => g.pciId).filter(id => id !== "")
    if (ids.length > 0 && !gpuNamesProcess.running) {
      gpuNamesProcess.command = ["sh", "-c", gpuNamesScript, "sh"].concat(ids)
      gpuNamesProcess.running = true
    }
  }

  // The cards' names, from the PCI id database the system already ships
  // (hwdata's pci.ids, as lspci uses). Read once at discovery. The device
  // line reads "Navi 22 [Radeon RX 6700/6700 XT/...]": the bracketed part is
  // the product, the rest the chip's codename. Capped like the other sweeps.
  readonly property string gpuNamesScript:
    "for f in /usr/share/hwdata/pci.ids /usr/share/misc/pci.ids; do [ -r \"$f\" ] && break; done; " +
    "awk -v want=\"$*\" 'BEGIN { n = split(want, w, \" \"); for (i = 1; i <= n; i++) W[w[i]] = 1 } " +
    "/^[0-9a-f][0-9a-f][0-9a-f][0-9a-f] / { v = $1; next } " +
    "/^\\t[0-9a-f][0-9a-f][0-9a-f][0-9a-f] / { id = v \":\" $1; if (id in W) { sub(/^\\t[0-9a-f]+ +/, \"\"); print id \"\\t\" $0 } }' " +
    "\"$f\" | head -c 4096"

  Process {
    id: gpuNamesProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var names = {}
        String(text).split("\n").forEach(line => {
          var tab = line.indexOf("\t")
          if (tab < 0) return
          var name = line.slice(tab + 1).replace(/[^\x20-\x7e]/g, "").trim()
          var bracket = /\[([^\]]+)\]/.exec(name)
          name = (bracket ? bracket[1] : name).slice(0, 80)
          if (name !== "") names[line.slice(0, tab)] = name
        })
        readers.sampler.applyGpuNames(names)
      }
    }
  }

  // The card's own hwmon: the one on the same PCI device. A hwmon that does
  // not report its slot falls back to the first unclaimed one named after the
  // card's driver, which is what a single-GPU machine always got.
  function gpuHwmon(card, used) {
    var keys = Object.keys(hwmonNames).sort((a, b) => Number(a.slice(5)) - Number(b.slice(5)))
    var pick = ""
    if (card.slot !== "") pick = keys.find(k => !used[k] && hwmonSlots[k] === card.slot) || ""
    if (pick === "") pick = keys.find(k => !used[k] && !hwmonSlots[k] && hwmonNames[k] === card.driver) || ""
    if (pick !== "") used[pick] = true
    return pick
  }

  // One set of readers per card, sampled on the strip's tick.
  Item {
    visible: false

    Repeater {
      id: gpuReaders
      model: readers.ready ? readers.sampler.gpus.length : 0
      delegate: Item {
        id: gpuReader
        required property int index
        readonly property var gpu: readers.sampler.gpus[index] || null
        readonly property string devicePath: gpu ? gpu.devicePath : ""
        // Not bound: the fallback below rewrites it, and a binding would be
        // broken by that write.
        property string powerPath: ""
        onGpuChanged: powerPath = gpu ? gpu.powerPath : ""
        property bool recordVram: false

        // Each card's readings are wanted on their own: pinning the second
        // card's power must not start reading its VRAM, or the main card's.
        readonly property bool wantBusy: readers.ready && readers.sampler.samplingGpu("gpu", index)
        readonly property bool wantVram: readers.ready && readers.sampler.samplingGpu("vram", index)
        readonly property bool wantTemperature: readers.ready && readers.sampler.samplingGpu("gputemp", index)
        readonly property bool wantPower: readers.ready && readers.sampler.samplingGpu("gpupower", index)

        function sample() {
          if (!gpu) return
          if (wantBusy) busyFile.reload()
          if (wantVram) readVram()
          if (wantTemperature && gpu.temperaturePath !== "") temperatureFile.reload()
          if (wantPower && powerPath !== "") powerFile.reload()
        }

        function readVram() {
          recordVram = wantVram
          vramUsedFile.reload()
          vramTotalFile.reload()
        }

        FileView {
          id: busyFile
          path: gpuReader.devicePath === "" ? "" : gpuReader.devicePath + "gpu_busy_percent"
          watchChanges: false
          printErrors: false
          onLoaded: if (readers.ready) readers.sampler.applyGpuBusy(gpuReader.index, readers.boundedText(this))
        }

        FileView {
          id: vramUsedFile
          path: gpuReader.devicePath === "" ? "" : gpuReader.devicePath + "mem_info_vram_used"
          watchChanges: false
          printErrors: false
          onLoaded: if (readers.ready) readers.sampler.applyVramUsed(gpuReader.index, readers.boundedText(this))
        }

        FileView {
          id: vramTotalFile
          path: gpuReader.devicePath === "" ? "" : gpuReader.devicePath + "mem_info_vram_total"
          watchChanges: false
          printErrors: false
          onLoaded: if (readers.ready)
            readers.sampler.applyVramTotal(gpuReader.index, readers.boundedText(this), gpuReader.recordVram)
        }

        FileView {
          id: temperatureFile
          path: gpuReader.gpu ? gpuReader.gpu.temperaturePath : ""
          watchChanges: false
          printErrors: false
          onLoaded: if (readers.ready) readers.sampler.applyGpuTemperature(gpuReader.index, readers.boundedText(this))
        }

        // Discrete amdgpu cards report the averaged power1_average; APUs and
        // newer kernels only the instantaneous power1_input, so a missing
        // average falls back to it once.
        FileView {
          id: powerFile
          path: gpuReader.powerPath
          watchChanges: false
          printErrors: false
          onLoaded: if (readers.ready && gpuReader.wantPower)
            readers.sampler.applyGpuPower(gpuReader.index, readers.boundedText(this))
          onLoadFailed: {
            if (!readers.ready || gpuReader.powerPath === "") return
            if (gpuReader.powerPath.endsWith("/power1_average"))
              gpuReader.powerPath = gpuReader.powerPath.replace(/power1_average$/, "power1_input")
            else readers.sampler.gpuPowerUnavailable(gpuReader.index)
          }
        }
      }
    }
  }

  // ---- Temperature sensors -----------------------------------------------

  property var hwmonNames: ({})
  property string temperatureInputPath: ""

  readonly property var sensorPreference: {
    if (!ready) return ["k10temp"]
    // `cputemp` is the documented key and the one the rest of the metric
    // already uses for range and urgent. `temperature` is the older name
    // this read alone still accepted, so it stays as a fallback rather than
    // silently dropping a config that used to work.
    var configured = String(sampler.config.cputemp.sensor)
    if (configured === "auto") configured = String(sampler.config.temperature.sensor)
    if (configured !== "auto") return [configured]
    // Package temperature first. The GPU and the drives are secondary
    // readings that the popup lists in their own right.
    return ["k10temp", "coretemp", "zenpower", "acpitz"]
  }

  Item {
    id: hwmonProbe
    visible: false

    Repeater {
      model: 16       // unconditional, same reason as the GPU probe above
      delegate: Item {
        id: hwmonSlot
        required property int index

        // The PCI device behind the sensor, which is what ties a GPU's
        // hwmon to its DRM card. Absent for sensors that are not on PCI.
        FileView {
          id: hwmonDevice
          path: "/sys/class/hwmon/hwmon" + hwmonSlot.index + "/device/uevent"
          watchChanges: false
          printErrors: false
          blockLoading: true
        }

        FileView {
          id: hwmonName
          path: "/sys/class/hwmon/hwmon" + hwmonSlot.index + "/name"
          watchChanges: false
          printErrors: false
          blockLoading: true

          Component.onCompleted: {
            readers.recordHwmon(hwmonSlot.index, hwmonName, hwmonDevice)
            readers.probeDone()
          }
        }
      }
    }
  }

  function recordHwmon(index, nameView, deviceView) {
    if (!ready) return
    // Bounded like the rest, and length-capped besides: this string is
    // retained in hwmonNames and reaches the popup as a label.
    var name = String(boundedText(nameView) || "").trim()
    if (name === "" || name.length > 64) return
    var slot = pciSlot(Parsers.parseUevent(boundedText(deviceView)).PCI_SLOT_NAME)
    if (slot !== "") {
      var slots = {}
      for (var s in hwmonSlots) slots[s] = hwmonSlots[s]
      slots["hwmon" + index] = slot
      hwmonSlots = slots
    }
    // Rebuilt as a fresh object: mutating the existing one and assigning it
    // back is the same reference, so QML sees no change and
    // onHwmonNamesChanged never fires.
    var map = {}
    for (var key in hwmonNames) map[key] = hwmonNames[key]
    map["hwmon" + index] = name
    hwmonNames = map
  }

  function resolveTemperatureSensor() {
    if (!ready) return
    var preference = sensorPreference
    for (var p = 0; p < preference.length; p++) {
      for (var key in hwmonNames) {
        if (hwmonNames[key] === preference[p]) {
          // temp1_input is the package channel by convention. On k10temp that
          // is Tctl, the value the firmware itself uses for thermal decisions;
          // per-CCD channels (Tccd1) are not package-representative.
          temperatureInputPath = "/sys/class/hwmon/" + key + "/temp1_input"
          sampler.temperatureLabel = preference[p]
          return
        }
      }
    }
  }

  onHwmonNamesChanged: resolveTemperatureSensor()

  FileView {
    id: temperatureFile
    path: readers.temperatureInputPath
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyTemperature(readers.boundedText(this))
  }

  // ---- Power -------------------------------------------------------------
  //
  // intel-rapl:0 is the package domain on AMD as well as Intel: the kernel's
  // amd RAPL support registers under the same powercap name. energy_uj is
  // mode 0400 unless a udev rule opens it (see README), and a refused read is
  // retried every tick rather than given up on, so granting access takes
  // effect without restarting the shell. A failed open is one syscall.
  FileView {
    id: energyFile
    path: "/sys/class/powercap/intel-rapl:0/energy_uj"
    watchChanges: false
    printErrors: false
    // Only reads a tick asked for. A FileView also loads by itself the moment
    // it gets its path, and that load used to become the energy baseline with
    // the first tick's read milliseconds behind it -- a small delta over a
    // tiny interval, logged as hundreds of watts on every shell start. Power
    // from a counter is only as good as the interval it is measured over, so
    // that interval has to be the sampling one.
    onLoaded: {
      if (!readers.ready || !readers.energyRequested) return
      readers.energyRequested = false
      readers.sampler.applyCpuEnergy(readers.boundedText(this))
    }
    onLoadFailed: {
      if (!readers.ready || !readers.energyRequested) return
      readers.energyRequested = false
      readers.sampler.cpuEnergyUnreadable()
    }
  }

  // World-readable, and fixed for the life of the machine: read once.
  FileView {
    id: energyRangeFile
    path: "/sys/class/powercap/intel-rapl:0/max_energy_range_uj"
    watchChanges: false
    printErrors: false
    blockLoading: true
    Component.onCompleted: if (readers.ready) readers.sampler.energyRangeUj = Parsers.parseFirstNumber(readers.boundedText(this))
  }
}

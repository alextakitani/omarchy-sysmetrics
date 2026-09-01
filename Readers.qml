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
  readonly property bool wantGpu: ready && sampler.sampling("gpu")
  readonly property bool wantVram: ready && sampler.sampling("vram")
  readonly property bool wantStorage: ready && sampler.sampling("storage")
  // Both GPU metrics come off the same card, so either one needs discovery.
  readonly property bool wantGpuDevice: wantGpu || wantVram || wantGpuTemperature
  readonly property bool wantTemperature: ready && sampler.sampling("cputemp")
  readonly property bool wantGpuTemperature: ready && sampler.sampling("gputemp")
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
    if (wantGpu && sampler.gpuCard !== "") gpuBusyFile.reload()
    if (wantVram && sampler.gpuCard !== "") {
      vramUsedFile.reload()
      vramTotalFile.reload()
    }
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
    if (wantGpuTemperature && gpuTemperatureInputPath !== "") gpuTemperatureFile.reload()

    // Popup-only detail: level readings with no history, so sampling them
    // lazily costs nothing and they are correct on the popup's first tick.
    // Uptime belongs here too — it is drawn only in the popup header, so
    // reading it every tick with the popup shut was a file read per interval,
    // all day, for a number nobody was looking at.
    if (ready && sampler.popupOpen) {
      uptimeFile.reload()
      if (wantCpu) loadavgFile.reload()
      if (wantGpu && !wantVram && sampler.gpuCard !== "") {
        vramUsedFile.reload()
        vramTotalFile.reload()
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
  Process {
    id: processesProcess
    command: ["sh", "-c",
              "getconf PAGESIZE; " +
              "(awk 'FNR==1{" +
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
              // A pid that exits between the glob expanding and awk opening
              // its file makes awk exit non-zero -- on a busy machine, most
              // sweeps. The output is complete regardless (every other file
              // was read and printed), so the status is discarded rather than
              // allowed to look like a failed read to anything downstream.
              "}' /proc/[0-9]*/stat 2>/dev/null || true) | head -c 262144"]
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

  Item {
    id: gpuProbe
    visible: false

    Repeater {
      model: 8        // unconditional: discovery runs once, not per popup open
      delegate: Item {
        id: gpuSlot
        required property int index

        FileView {
          id: gpuUevent
          path: "/sys/class/drm/card" + gpuSlot.index + "/device/uevent"
          watchChanges: false
          printErrors: false
          blockLoading: true

          Component.onCompleted: {
            if (!readers.ready || readers.sampler.gpuCard !== "") return
            if (readers.configuredGpuCard !== "") {
              readers.sampler.gpuCard = readers.configuredGpuCard
              return
            }
            var fields = Parsers.parseUevent(readers.boundedText(gpuUevent))
            var driver = fields.DRIVER ? String(fields.DRIVER) : ""
            if (readers.gpuDrivers.indexOf(driver) >= 0)
              readers.sampler.gpuCard = "card" + gpuSlot.index
          }
        }
      }
    }
  }

  readonly property var gpuDrivers: ["amdgpu", "i915", "xe", "nouveau", "nvidia", "radeon"]

  // gpu.card lets a multi-GPU machine name the card instead of taking the
  // first one whose driver is recognised. It becomes a path segment, so it
  // is accepted only in exactly the shape the kernel uses -- "card" followed
  // by digits. Anything else is ignored in favour of discovery rather than
  // concatenated into /sys/class/drm/<...>/device/.
  readonly property string configuredGpuCard: {
    if (!ready) return ""
    var configured = String(sampler.config.gpu.card)
    return /^card\d{1,3}$/.test(configured) ? configured : ""
  }

  readonly property string gpuDevicePath: sampler && sampler.gpuCard !== ""
    ? "/sys/class/drm/" + sampler.gpuCard + "/device/"
    : ""

  FileView {
    id: gpuBusyFile
    path: readers.gpuDevicePath === "" ? "" : readers.gpuDevicePath + "gpu_busy_percent"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyGpuBusy(readers.boundedText(this))
  }

  FileView {
    id: vramUsedFile
    path: readers.gpuDevicePath === "" ? "" : readers.gpuDevicePath + "mem_info_vram_used"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.gpuVramUsed = Parsers.parseFirstNumber(readers.boundedText(this))
  }

  FileView {
    id: vramTotalFile
    path: readers.gpuDevicePath === "" ? "" : readers.gpuDevicePath + "mem_info_vram_total"
    watchChanges: false
    printErrors: false
    onLoaded: {
      if (!readers.ready) return
      readers.sampler.gpuVramTotal = Parsers.parseFirstNumber(readers.boundedText(this))
      // Total arrives after used in the same tick, so this is the point at
      // which the pair is consistent enough to record.
      if (readers.wantVram) readers.sampler.recordVram()
    }
  }

  // ---- Temperature sensors -----------------------------------------------

  property var hwmonNames: ({})
  property string temperatureInputPath: ""
  property string gpuTemperatureInputPath: ""

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

        FileView {
          id: hwmonName
          path: "/sys/class/hwmon/hwmon" + hwmonSlot.index + "/name"
          watchChanges: false
          printErrors: false
          blockLoading: true

          Component.onCompleted: {
            // Bounded like the rest, and length-capped besides: this string
            // is retained in hwmonNames and reaches the popup as a label.
            var name = String(readers.boundedText(hwmonName) || "").trim()
            if (name === "" || name.length > 64) return
            // Rebuilt as a fresh object: mutating the existing one and
            // assigning it back is the same reference, so QML sees no change
            // and onHwmonNamesChanged never fires.
            var map = {}
            for (var key in readers.hwmonNames) map[key] = readers.hwmonNames[key]
            map["hwmon" + hwmonSlot.index] = name
            readers.hwmonNames = map
          }
        }
      }
    }
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

  function resolveGpuTemperatureSensor() {
    if (!ready) return
    // amdgpu/nouveau expose the die reading as temp1_input, labelled "edge"
    // on amdgpu; nvidia's is surfaced the same way by its kernel driver.
    // A configured gputemp.sensor names the hwmon directly and wins, which
    // is what the README documents; "auto" falls back to driver identity.
    var configured = String(sampler.config.gputemp.sensor)
    var drivers = configured !== "auto"
      ? [configured]
      : ["amdgpu", "nouveau", "nvidia"]
    for (var d = 0; d < drivers.length; d++) {
      for (var key in hwmonNames) {
        if (hwmonNames[key] === drivers[d]) {
          gpuTemperatureInputPath = "/sys/class/hwmon/" + key + "/temp1_input"
          return
        }
      }
    }
  }

  onHwmonNamesChanged: {
    resolveTemperatureSensor()
    resolveGpuTemperatureSensor()
  }

  FileView {
    id: temperatureFile
    path: readers.temperatureInputPath
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyTemperature(readers.boundedText(this))
  }

  FileView {
    id: gpuTemperatureFile
    path: readers.gpuTemperatureInputPath
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyGpuTemperature(readers.boundedText(this))
  }

}

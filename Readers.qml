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

  function sampleAll() {
    if (!ready) return
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
      if (storageTicks <= 0) {
        if (!dfProcess.running) dfProcess.running = true
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
  }

  property int routeTicks: 0
  property int storageTicks: 0

  // Bound a recurring FileView read BEFORE it becomes a QML string.
  //
  // The parsers carry byte ceilings of their own, but a post-read check is
  // too late to matter: by the time parseNetDev() sees text(), FileView has
  // already read the whole file and converted every byte of it to UTF-16.
  // The allocation the ceiling exists to prevent has happened. Row counts in
  // these files are decided outside this plugin -- interfaces come and go,
  // block devices appear -- and every one of them is read on the sampling
  // timer inside the shared shell, so the read is what needs the ceiling.
  //
  // data() hands back an ArrayBuffer, so byteLength is the on-disk size
  // without paying for the string conversion. Over the ceiling, the file is
  // dropped whole and the metric skips the tick: a missing reading is better
  // than a torn one, and better than a multi-megabyte string per tick.
  //
  // The parser ceilings stay where they are. They are the same rule enforced
  // one layer in, for callers that reach a parser without coming through
  // here -- the tests do exactly that.
  function boundedText(view) {
    var buffer = view.data()
    if (!buffer) return ""
    if (buffer.byteLength >= Parsers.PROC_MAX_BYTES) return ""
    return view.text()
  }

  // Exposed so the runtime suite can exercise boundedText against a real
  // FileView rather than a stand-in.
  readonly property alias statFileView: statFile

  FileView {
    id: statFile
    path: "/proc/stat"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyProcStat(readers.boundedText(this))
  }

  FileView {
    id: uptimeFile
    path: "/proc/uptime"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyUptime(text())
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

  FileView {
    id: meminfoFile
    path: "/proc/meminfo"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyMeminfo(text())
  }

  FileView {
    id: routeFile
    path: "/proc/net/route"
    watchChanges: false
    printErrors: false
    onLoaded: {
      if (!readers.ready) return
      var resolved = readers.sampler.resolveInterface(text())
      if (resolved !== readers.sampler.networkInterface) {
        // Switching interfaces invalidates the byte baseline.
        readers.sampler.networkInterface = resolved
        readers.sampler.previousNetwork = null
        readers.sampler.previousNetworkAt = 0
      }
    }
  }

  FileView {
    id: netDevFile
    path: "/proc/net/dev"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyNetDev(readers.boundedText(this))
  }

  FileView {
    id: diskstatsFile
    path: "/proc/diskstats"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyDiskstats(readers.boundedText(this))
  }

  FileView {
    id: loadavgFile
    path: "/proc/loadavg"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.loadAverage = Parsers.parseLoadavg(text())
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
            var fields = Parsers.parseUevent(gpuUevent.text())
            var driver = fields.DRIVER ? String(fields.DRIVER) : ""
            if (readers.gpuDrivers.indexOf(driver) >= 0)
              readers.sampler.gpuCard = "card" + gpuSlot.index
          }
        }
      }
    }
  }

  readonly property var gpuDrivers: ["amdgpu", "i915", "xe", "nouveau", "nvidia", "radeon"]

  readonly property string gpuDevicePath: sampler && sampler.gpuCard !== ""
    ? "/sys/class/drm/" + sampler.gpuCard + "/device/"
    : ""

  FileView {
    id: gpuBusyFile
    path: readers.gpuDevicePath === "" ? "" : readers.gpuDevicePath + "gpu_busy_percent"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyGpuBusy(text())
  }

  FileView {
    id: vramUsedFile
    path: readers.gpuDevicePath === "" ? "" : readers.gpuDevicePath + "mem_info_vram_used"
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.gpuVramUsed = Parsers.parseFirstNumber(text())
  }

  FileView {
    id: vramTotalFile
    path: readers.gpuDevicePath === "" ? "" : readers.gpuDevicePath + "mem_info_vram_total"
    watchChanges: false
    printErrors: false
    onLoaded: {
      if (!readers.ready) return
      readers.sampler.gpuVramTotal = Parsers.parseFirstNumber(text())
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
    var configured = String(sampler.config.temperature.sensor)
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
            var name = String(hwmonName.text() || "").trim()
            if (name === "") return
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
    var drivers = ["amdgpu", "nouveau", "nvidia"]
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
    onLoaded: if (readers.ready) readers.sampler.applyTemperature(text())
  }

  FileView {
    id: gpuTemperatureFile
    path: readers.gpuTemperatureInputPath
    watchChanges: false
    printErrors: false
    onLoaded: if (readers.ready) readers.sampler.applyGpuTemperature(text())
  }

}

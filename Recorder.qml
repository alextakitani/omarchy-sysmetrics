import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import "js/log.js" as Log
import "js/parsers.js" as Parsers

// Writes the chosen metrics to disk for later analysis.
//
// Each recording opens one long-lived writer per file and feeds it rows over
// its stdin, so the recurring cost is formatting a line and one pipe write:
// no file open, no rewrite of a growing file per tick. Once a minute the
// writer seals what it has into a zstd frame appended to the file and fsyncs
// it, so a crash of the whole machine loses at most that last minute. Numeric
// CSV compresses around eightfold even in minute-sized frames, so a day at the
// default interval is under a megabyte on disk.
//
// Rows are written from the sampler's latest completed readings, so `t_ms` is
// when the row was written and the values are at most one interval older.
//
// Files land in $XDG_STATE_HOME/omarchy-sysmetrics/logs/, named by the start
// time (to the millisecond): <stamp>-metrics.csv.zst and <stamp>-processes.csv.zst.
Item {
  id: recorder
  visible: false

  property QtObject sampler: null
  property string processSweepScript: ""
  // What to log (config.logMetrics). Changing it mid-recording starts a new
  // pair of files: a CSV whose columns change halfway is not one table.
  property var selection: []

  property bool active: false
  property double startedAt: 0
  property double elapsedMs: 0

  // Process CPU is measured over a window rather than per tick: a sweep is a
  // fork, and a 30s window already answers "who used the CPU" -- summed over a
  // day, the per-window CPU seconds are each process's total.
  readonly property int processWindowMs: 30000

  // How often the writers seal a frame onto disk: the most a crash can lose.
  readonly property int flushMs: 60000
  property double lastFlushAt: 0

  readonly property string directory: {
    var state = Quickshell.env("XDG_STATE_HOME")
    return (state ? state : Quickshell.env("HOME") + "/.local/state") + "/omarchy-sysmetrics/logs"
  }

  // The selection a running session was started with. Every settings write
  // hands this a fresh array, so a change is judged by content: stepping the
  // interval must not split a recording into two files.
  property string sessionSelection: ""

  // Created first, so the button works before the first recording too. A
  // login bash, as the shell's own launchers use, so xdg-open and the file
  // manager get the session's PATH and environment.
  function openDirectory() {
    Quickshell.execDetached(["bash", "-lc", "mkdir -p \"$1\" && exec xdg-open \"$1\"", "bash", directory])
  }

  function start() {
    startedAt = Date.now()
    elapsedMs = 0
    lastSweepAt = 0
    lastFlushAt = startedAt
    previousTicks = ({})
    rotate()
    active = true
  }

  // A new pair of files for a recording already running. The recording
  // itself carries on -- its clock and the process baseline are untouched, so
  // the next process window still has its CPU column.
  function rotate() {
    sessionSelection = selection.join(",")
    session.active = false
    session.active = true
  }

  // Seals every row written so far onto disk.
  function flush() {
    lastFlushAt = Date.now()
    var s = session.item
    if (!s) return
    if (s.metricsWriter.ready) s.metricsWriter.write("\n")
    if (s.processesWriter.ready) s.processesWriter.write("\n")
  }

  // Hands the logs to the default agent (Omarchy's `omarchy agent prompt`),
  // started in the logs folder. A running recording is flushed first, so the
  // agent sees everything up to the click.
  function analyze() {
    if (active) flush()
    Quickshell.execDetached(["bash", "-lc", "cd \"$1\" && exec omarchy-agent-prompt \"$2\"",
                             "bash", directory, Log.analysisPrompt(directory)])
  }

  // Dropping the session destroys the writers, which closes their stdin; each
  // zstd sees end of input and finishes its file. See LogWriter for why that
  // holds even when the shell itself is going away.
  function stop() {
    active = false
    session.active = false
  }

  // Whether a recording should be running (config.recording). Persisted, so a
  // shell restart halfway through a day resumes into a fresh pair of files
  // instead of silently ending the log.
  // The binding's first evaluation already raises this, so there is no
  // separate start on completion -- two starts would race for one file name.
  property bool wanted: false
  onWantedChanged: wanted ? start() : stop()

  onSelectionChanged: if (active && selection.join(",") !== sessionSelection) rotate()

  function snapshot() {
    var s = sampler
    var mem = s.memory
    return {
      cpu: s.cpuUsage,
      cpuAvg: s.cpuAggregate,
      cputemp: s.temperature,
      mem: mem.percent,
      // 0 when swap is idle, unlike the plot: a log should say "none used".
      // Empty only when there is no swap at all.
      swap: mem.swapTotalKB > 0 ? mem.swapUsedKB * 100 / mem.swapTotalKB : NaN,
      gpu: s.gpuUsage,
      vram: s.vramPercent,
      gputemp: s.gpuTemperature,
      rx: s.networkRx,
      tx: s.networkTx,
      read: s.diskRead,
      write: s.diskWrite,
      storage: s.storagePercent,
      cpuPower: s.cpuPower,
      gpuPower: s.gpuPower
    }
  }

  // Called by the sampling timer, before it starts the next round of reads.
  function tick() {
    if (!active || !sampler || !session.item) return
    var now = Date.now()
    elapsedMs = now - startedAt
    var s = session.item
    if (s.metricsWriter.ready)
      s.metricsWriter.write(Log.metricsRow(s.metricIds, snapshot(), now))
    if (now - lastFlushAt >= flushMs) flush()

    if (!s.withProcesses) return
    if (sweep.running) {
      // Same wedge guard as the popup's sweep: a child that never returns
      // must not freeze the log. Judged by age, not by "still running on the
      // next tick" -- a sweep at shell startup can outlast one short tick,
      // and killing it midway left a baseline missing most pids.
      if (now - sweepStartedAt > 10000) sweep.running = false
    } else if (now - lastSweepAt >= processWindowMs) {
      sweepStartedAt = now
      sweep.running = true
    }
  }

  property double lastSweepAt: 0
  property double sweepStartedAt: 0
  property var previousTicks: ({})

  function applySweep(text) {
    var now = Date.now()
    var body = text
    var pageSize = 4096
    var newline = body.indexOf("\n")
    if (newline > 0) {
      var reported = Number(body.slice(0, newline))
      if (isFinite(reported) && reported > 0) pageSize = reported
      body = body.slice(newline + 1)
    }
    var rows = Parsers.parseProcessTable(body)
    if (rows.length === 0) return        // a failed sweep, not an empty machine

    var dt = lastSweepAt > 0 ? now - lastSweepAt : 0
    var withCpu = Parsers.processCpuPercents(previousTicks, rows, dt)
    for (var i = 0; i < withCpu.length; i++) withCpu[i].rssBytes = withCpu[i].rssPages * pageSize
    previousTicks = Parsers.processTicksByPid(rows)
    lastSweepAt = now

    // The first sweep of a recording only sets the baseline.
    if (dt > 0 && session.item && session.item.processesWriter.ready)
      session.item.processesWriter.write(Log.processRows(withCpu, dt, now))
  }

  Process {
    id: sweep
    command: ["sh", "-c", recorder.processSweepScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: recorder.applySweep(text)
    }
  }

  // One stream into one compressed file, as a run of zstd frames.
  //
  // A single long-lived zstd writes nothing until a full 128 KiB input block
  // has arrived -- twenty minutes of rows -- so a machine crash lost the whole
  // recording. Instead awk passes rows to a zstd, and an empty line (which no
  // CSV row is) makes it close that zstd: the frame is finished, appended and
  // fsynced, and the next row starts a new one. Concatenated frames are one
  // valid .zst; a frame cut short by a crash still lets `zstd -dc` print every
  // row before it.
  //
  // The shell creates the file up front, so it is there from the first
  // second. `set -C` refuses to overwrite one, and the stamp carries
  // milliseconds so a restart within the same second never meets it.
  //
  // awk runs as a background child of the sh, reading the sh's stdin, and the
  // sh waits on it. If the shell tears this Process down by killing it, only
  // the sh dies: awk keeps running until the pipe's write end closes -- which
  // happens as the shell lets go of it -- then seals the last frame. Exec'ing
  // it directly would put it in the line of fire and lose the tail on every
  // shell restart.
  //
  // `0<&0` because a non-interactive sh points an `&` job's stdin at
  // /dev/null; the explicit redirection keeps the pipe.
  component LogWriter: Process {
    property string path: ""
    property string header: ""
    // Rows written while the process is still starting would reach the file
    // ahead of the header, so nothing is written until it has gone out.
    property bool ready: false
    stdinEnabled: true
    command: ["sh", "-c", "set -C; mkdir -p \"$(dirname \"$1\")\" && : >\"$1\" && { F=\"$1\" awk "
              + "'BEGIN { z = \"zstd -q -c >>\\\"$F\\\" && sync \\\"$F\\\"\" } NF == 0 { close(z); next } { print | z } END { close(z) }'"
              + " 0<&0 & wait; }", "sh", path]
    running: path !== ""
    onStarted: {
      write(header)
      ready = true
    }
  }

  Loader {
    id: session
    active: false
    sourceComponent: Item {
      id: current
      // Fixed when the session starts rather than bound: a selection change
      // replaces the whole session, and a binding here could otherwise move
      // a live writer's path or header under it first.
      property string stamp: ""
      property var metricIds: []
      property bool withProcesses: false
      Component.onCompleted: {
        stamp = Qt.formatDateTime(new Date(), "yyyy-MM-dd'T'HH-mm-ss.zzz")
        metricIds = Log.metricIds(recorder.selection)
        withProcesses = recorder.selection.indexOf("processes") >= 0
      }
      property alias metricsWriter: metricsWriter
      property alias processesWriter: processesWriter

      LogWriter {
        id: metricsWriter
        path: current.metricIds.length > 0 ? recorder.directory + "/" + current.stamp + "-metrics.csv.zst" : ""
        header: Log.metricsHeader(current.metricIds)
      }

      LogWriter {
        id: processesWriter
        path: current.withProcesses ? recorder.directory + "/" + current.stamp + "-processes.csv.zst" : ""
        header: Log.PROCESS_HEADER
      }
    }
  }

  // Whether there is anything to analyze, for the popup's analyze button.
  //
  // Watched rather than polled: FolderListModel follows the directory through
  // the kernel's file watcher, so this costs nothing per tick. It cannot see a
  // directory created after it starts watching, though, so the directory is
  // made first -- one mkdir per shell start -- and only then handed over.
  readonly property bool hasLogs: logFiles.count > 0
  property bool directoryReady: false

  Process {
    command: ["mkdir", "-p", recorder.directory]
    running: true
    onExited: recorder.directoryReady = true
  }

  FolderListModel {
    id: logFiles
    folder: recorder.directoryReady ? "file://" + recorder.directory : ""
    nameFilters: ["*.csv.zst"]
    showDirs: false
  }
}

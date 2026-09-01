import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format

// The ten processes holding the most resident memory.
//
// Ranked by RSS, which is what the process actually has in RAM -- not its
// virtual size, which counts mappings that were never faulted in and would
// put every process that mmap'd a large file at the top. RSS double-counts
// shared pages across processes, so these rows do not sum to the machine's
// used memory; they answer "which process is holding the most", which is the
// question being asked.
//
// Shares the CPU list's sweep and its collapsed-by-default gating: expanding
// either one is what turns the reading on.
DetailSection {
  id: root

  property QtObject sampler: null
  readonly property int revisionTick: sampler ? sampler.revisionOf("processes") : 0

  readonly property var processes: {
    void revisionTick
    return sampler ? sampler.topMemoryProcesses : []
  }

  // The bars are drawn against total RAM, so a row's fill is its share of the
  // machine rather than of the largest row -- which would make the top
  // process look pegged no matter how little it held.
  readonly property real memoryTotalBytes: {
    var mem = sampler ? sampler.memory : null
    return mem && mem.totalKB > 0 ? mem.totalKB * 1024 : NaN
  }

  title: "Top processes · memory"
  collapsible: true

  headline: processes.length > 0
    ? Format.formatBytes(processes[0].rssBytes)
    : Format.DASH

  Repeater {
    model: root.processes

    delegate: ProcessRow {
      required property var modelData

      Layout.fillWidth: true
      comm: modelData.comm
      pid: modelData.pid
      reading: modelData.rssBytes
      bytes: true
      ceiling: root.memoryTotalBytes
    }
  }

  // Memory needs no baseline, so this only shows before the first sweep lands.
  Text {
    Layout.fillWidth: true
    visible: root.processes.length === 0
    text: "Sampling…"
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}

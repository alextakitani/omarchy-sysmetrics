import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format

// The ten processes using the most CPU right now.
//
// Collapsed by default, and it samples only while open: the reading behind it
// is a sweep of every /proc/<pid>/stat on the machine, which is the dearest
// read in this plugin by a wide margin. Nothing pays for it until it is asked
// for.
DetailSection {
  id: root

  property QtObject sampler: null
  readonly property int revisionTick: sampler ? sampler.revisionOf("processes") : 0

  readonly property var processes: {
    void revisionTick
    return sampler ? sampler.topCpuProcesses : []
  }

  title: "Top processes · CPU"
  collapsible: true

  // Percent of ONE core, so a threaded process legitimately passes 100 -- the
  // same reading top gives. The headline is the busiest single process, which
  // is the number the list is there to surface.
  //
  // Shown collapsed as well as open: it is the reading that tells you whether
  // opening the list is worth it, and blanking it on collapse would hide the
  // one number a shut section can still usefully carry.
  headline: processes.length > 0
    ? Format.formatPercent(processes[0].cpuPercent)
    : Format.DASH

  // The Repeater sits directly in the section, as Storage's does. Wrapping
  // the rows in a layout of their own instead left that wrapper with no
  // width, and the whole list collapsed to the height of one row.
  Repeater {
    model: root.processes

    delegate: ProcessRow {
      required property var modelData

      Layout.fillWidth: true
      comm: modelData.comm
      pid: modelData.pid
      reading: modelData.cpuPercent
      ceiling: 100
    }
  }

  // Empty for exactly one sweep after expanding: the CPU column is a delta,
  // so the first sweep only establishes the baseline. Saying so beats a blank
  // gap that reads as a broken panel.
  Text {
    Layout.fillWidth: true
    visible: root.processes.length === 0
    text: "Sampling…"
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}

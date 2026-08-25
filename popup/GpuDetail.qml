import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format
import "../js/engine.js" as Engine

DetailSection {
  id: root

  property QtObject sampler: null
  // Re-read the rings whenever a new sample lands.
  readonly property int revisionTick: sampler ? sampler.revision : 0

  readonly property real gpuUsage: sampler ? sampler.gpuUsage : NaN
  readonly property string gpuCard: sampler ? sampler.gpuCard : ""

  title: "Graphics"
  headline: Format.formatPercent(gpuUsage)
  visible: root.gpuCard !== ""

  // Columns, not a line: GPU busy% rests at zero much of the time, and a line
  // drawn between two idle samples interpolates activity that never happened.
  DetailChart {
    Layout.fillWidth: true
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      return root.sampler ? Engine.ringValues(root.sampler.gpuHistory) : []
    }
    mode: "columns"
    revision: root.sampler ? root.sampler.revision : 0
  }

  MeterRow {
    Layout.fillWidth: true
    label: "Busy"
    value: Format.formatPercent(root.gpuUsage)
    ratio: isNaN(root.gpuUsage) ? NaN : root.gpuUsage / 100
    urgent: !isNaN(root.gpuUsage) && root.gpuUsage >= 95
  }

}

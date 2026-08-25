import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format
import "../js/engine.js" as Engine

// Video memory occupancy. Separate from Graphics because it answers a
// different question — how full the card's memory is, not how busy its
// processor is — and because each metric needs its own header to be pinned or
// hidden independently.
DetailSection {
  id: root

  property QtObject sampler: null
  // Re-read the rings whenever a new sample lands.
  readonly property int revisionTick: sampler ? sampler.revision : 0

  readonly property real percent: sampler ? sampler.vramPercent : NaN
  readonly property real used: sampler ? sampler.gpuVramUsed : NaN
  readonly property real total: sampler ? sampler.gpuVramTotal : NaN
  readonly property string gpuCard: sampler ? sampler.gpuCard : ""

  title: "VRAM"
  headline: Format.formatPercent(percent)
  visible: root.gpuCard !== ""

  DetailChart {
    Layout.fillWidth: true
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      return root.sampler ? Engine.ringValues(root.sampler.vramHistory) : []
    }
    revision: root.sampler ? root.sampler.revision : 0
    stroke: !isNaN(root.percent) && root.percent >= 90 ? Color.urgent : Color.accent
  }

  MeterRow {
    Layout.fillWidth: true
    label: "Used"
    value: Format.formatBytes(root.used) + " of " + Format.formatBytes(root.total)
    ratio: (isNaN(root.used) || isNaN(root.total) || root.total <= 0)
      ? NaN : root.used / root.total
    urgent: !isNaN(root.percent) && root.percent >= 90
  }
}

import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format
import "../js/engine.js" as Engine

// Video memory occupancy of one card. Separate from Graphics because it
// answers a different question — how full the card's memory is, not how busy
// its processor is — and because each metric needs its own header to be
// pinned or hidden independently.
DetailSection {
  id: root

  property QtObject sampler: null
  property int gpuIndex: 0
  // Re-read the rings whenever a new sample lands.
  readonly property int revisionTick: sampler ? sampler.revisionOf("vram") : 0

  readonly property var gpu: sampler ? (sampler.gpus[gpuIndex] || null) : null
  readonly property real used: { void revisionTick; return gpu ? gpu.vramUsed : NaN }
  readonly property real total: { void revisionTick; return gpu ? gpu.vramTotal : NaN }
  readonly property real percent: (total > 0 && !isNaN(used)) ? used * 100 / total : NaN

  // The name lands after discovery (gpuLabels changes with it); the card
  // entry itself is the same object, so it is that change being watched.
  title: { void (sampler ? sampler.gpuLabels : null); return gpu ? "VRAM · " + gpu.label : "VRAM" }
  headline: Format.formatPercent(percent)
  visible: root.gpu !== null

  DetailChart {
    Layout.fillWidth: true
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      return root.gpu ? Engine.ringValues(root.gpu.vramHistory) : []
    }
    revision: root.revisionTick
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

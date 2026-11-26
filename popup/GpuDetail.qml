import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format
import "../js/engine.js" as Engine

// One card's busy time. A machine with several GPUs gets one of these per
// card, each pinned and logged on its own.
DetailSection {
  id: root

  property QtObject sampler: null
  property int gpuIndex: 0
  // Re-read the rings whenever a new sample lands.
  readonly property int revisionTick: sampler ? sampler.revisionOf("gpu") : 0

  readonly property var gpu: sampler ? (sampler.gpus[gpuIndex] || null) : null
  readonly property real gpuUsage: { void revisionTick; return gpu ? gpu.usage : NaN }

  // Named after the card, so two GPUs read as two products, not as numbers.
  // The name lands after discovery (gpuLabels changes with it); the card
  // entry itself is the same object, so it is that change being watched.
  title: { void (sampler ? sampler.gpuLabels : null); return gpu ? "GPU · " + gpu.label : "GPU" }
  headline: Format.formatPercent(gpuUsage)
  visible: root.gpu !== null

  // Columns, not a line: GPU busy% rests at zero much of the time, and a line
  // drawn between two idle samples interpolates activity that never happened.
  DetailChart {
    Layout.fillWidth: true
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      return root.gpu ? Engine.ringValues(root.gpu.usageHistory) : []
    }
    mode: "columns"
    revision: root.revisionTick
  }

  MeterRow {
    Layout.fillWidth: true
    label: "Busy"
    value: Format.formatPercent(root.gpuUsage)
    ratio: isNaN(root.gpuUsage) ? NaN : root.gpuUsage / 100
    urgent: !isNaN(root.gpuUsage) && root.gpuUsage >= 95
  }
}

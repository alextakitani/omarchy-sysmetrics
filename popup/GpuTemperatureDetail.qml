import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format
import "../js/engine.js" as Engine

// One card's die temperature. Same treatment as the CPU sensor: an unfilled
// line across the band it actually lives in, with the urgent zone shaded.
DetailSection {
  id: root

  property QtObject sampler: null
  property int gpuIndex: 0
  // Re-read the rings whenever a new sample lands.
  readonly property int revisionTick: sampler ? sampler.revisionOf("gputemp") : 0

  readonly property var gpu: sampler ? (sampler.gpus[gpuIndex] || null) : null
  readonly property real temperature: { void revisionTick; return gpu ? gpu.temperature : NaN }

  // The name lands after discovery (gpuLabels changes with it); the card
  // entry itself is the same object, so it is that change being watched.
  title: { void (sampler ? sampler.gpuLabels : null); return gpu ? "Temperature · " + gpu.label : "GPU temperature" }
  headline: Format.formatTempShort(temperature)
  visible: root.gpu !== null && root.gpu.temperaturePath !== ""

  DetailChart {
    Layout.fillWidth: true
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      return root.gpu ? Engine.ringValues(root.gpu.temperatureHistory) : []
    }
    mode: "line"
    floorValue: 30
    ceiling: 95
    urgentAt: 85
    showThreshold: true
    revision: root.revisionTick
    stroke: !isNaN(root.temperature) && root.temperature >= 85 ? Color.urgent : Color.accent
  }
}

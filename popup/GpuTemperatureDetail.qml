import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format
import "../js/engine.js" as Engine

// GPU die temperature. Same treatment as the CPU sensor: an unfilled line
// across the band it actually lives in, with the urgent zone shaded.
DetailSection {
  id: root

  property QtObject sampler: null
  // Re-read the rings whenever a new sample lands.
  readonly property int revisionTick: sampler ? sampler.revision : 0

  readonly property real temperature: sampler ? sampler.gpuTemperature : NaN

  function normalize(celsius) {
    if (isNaN(celsius)) return NaN
    return Math.max(0, Math.min(1, (celsius - 30) / (95 - 30)))
  }

  title: "GPU temperature"
  headline: Format.formatTempShort(temperature)

  DetailChart {
    Layout.fillWidth: true
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      return root.sampler ? Engine.ringValues(root.sampler.gpuTemperatureHistory) : []
    }
    mode: "line"
    floorValue: 30
    ceiling: 95
    urgentAt: 85
    showThreshold: true
    revision: root.sampler ? root.sampler.revision : 0
    stroke: !isNaN(root.temperature) && root.temperature >= 85 ? Color.urgent : Color.accent
  }

  MeterRow {
    Layout.fillWidth: true
    label: "Die"
    value: Format.formatTempFull(root.temperature)
    ratio: root.normalize(root.temperature)
    urgent: !isNaN(root.temperature) && root.temperature >= 85
  }
}

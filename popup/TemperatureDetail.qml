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

  readonly property real temperature: sampler ? sampler.temperature : NaN
  readonly property string temperatureLabel: sampler ? sampler.temperatureLabel : ""
  readonly property var sensors: sampler ? sampler.temperatureSensors : []

  // Normalize a Celsius reading over a fixed 30..95 range so the meter has a
  // visually meaningful scale; values outside the range clamp rather than
  // overflow/underflow the track.
  function normalize(celsius) {
    if (isNaN(celsius)) return NaN
    var ratio = (celsius - 30) / (95 - 30)
    return Math.max(0, Math.min(1, ratio))
  }

  title: "CPU temperature"
  headline: Format.formatTempShort(temperature)

  // Unfilled line across the 30-95 band, never a filled area from zero: a
  // fill states "this much of something" and so forces a zero baseline, which
  // would squash the whole idle-to-throttle range into a couple of pixels.
  // The urgent zone is shaded so the warning is carried by position too, not
  // by colour alone.
  DetailChart {
    Layout.fillWidth: true
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      return root.sampler ? Engine.ringValues(root.sampler.temperatureHistory) : []
    }
    mode: "line"
    floorValue: 30
    ceiling: 95
    urgentAt: 85
    showThreshold: true
    revision: root.sampler ? root.sampler.revision : 0
    stroke: !isNaN(root.temperature) && root.temperature >= 85 ? Color.urgent : Color.accent
  }

  Repeater {
    model: root.sensors && root.sensors.length > 0 ? root.sensors : []

    delegate: MeterRow {
      id: sensorRow
      required property var modelData

      Layout.fillWidth: true
      label: sensorRow.modelData.label
      value: Format.formatTempFull(sensorRow.modelData.celsius)
      ratio: root.normalize(sensorRow.modelData.celsius)
      urgent: !isNaN(sensorRow.modelData.celsius) && sensorRow.modelData.celsius >= 85
    }
  }
}

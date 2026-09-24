import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format
import "../js/engine.js" as Engine

// Power drawn by one device: the CPU package (RAPL) or the GPU (its driver's
// power sensor). One section per device, like the temperatures, so each can
// be pinned and logged on its own. The board, drives and fans are unmetered,
// so the two together are less than the draw at the wall.
DetailSection {
  id: root

  property QtObject sampler: null
  property string device: "cpu"          // "cpu" or "gpu"
  readonly property bool isCpu: device === "cpu"
  readonly property int revisionTick: sampler ? sampler.revisionOf(isCpu ? "cpupower" : "gpupower") : 0

  readonly property real watts: sampler ? (isCpu ? sampler.cpuPower : sampler.gpuPower) : NaN
  // Only RAPL is ever refused; the GPU sensor is readable by everyone.
  readonly property bool readable: !isCpu || (sampler ? sampler.cpuPowerReadable : true)

  title: isCpu ? "CPU power" : "GPU power"
  headline: readable ? Format.formatWatts(watts) : "no access"
  visible: isCpu || (sampler ? sampler.hasGpuPowerSensor : false)

  // Dimmed rather than hidden while RAPL is refused: the chart stays where it
  // will be once access is granted, and the note below says why it is empty.
  DetailChart {
    Layout.fillWidth: true
    opacity: root.readable ? 1 : 0.35
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      if (!root.sampler) return []
      return Engine.ringValues(root.isCpu ? root.sampler.cpuPowerHistory : root.sampler.gpuPowerHistory)
    }
    // Floored so an idle desktop does not fill the chart.
    ceiling: {
      void root.revisionTick
      if (!root.sampler) return 50
      return Engine.rollingCeiling([Engine.ringValues(root.isCpu ? root.sampler.cpuPowerHistory
                                                                  : root.sampler.gpuPowerHistory)], 50)
    }
    mode: "area"
    revision: root.revisionTick
  }

  // RAPL is root-only by default. Saying so beats a dash that reads as a
  // broken sensor.
  Text {
    Layout.fillWidth: true
    visible: !root.readable
    text: "Needs read access to RAPL — see the README."
    wrapMode: Text.WordWrap
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}

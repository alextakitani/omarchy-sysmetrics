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

  readonly property var mem: sampler ? sampler.memory : null
  readonly property real percent: mem ? mem.percent : NaN
  readonly property real usedKB: mem ? mem.usedKB : NaN
  readonly property real totalKB: mem ? mem.totalKB : NaN
  readonly property real availableKB: mem ? mem.availableKB : NaN
  readonly property real cachedKB: mem ? mem.cachedKB : NaN
  readonly property real buffersKB: mem ? mem.buffersKB : NaN
  readonly property real swapTotalKB: mem ? mem.swapTotalKB : NaN
  readonly property real swapUsedKB: mem ? mem.swapUsedKB : NaN

  title: "Memory"
  headline: Format.formatPercent(percent)

  DetailChart {
    Layout.fillWidth: true
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      return root.sampler ? Engine.ringValues(root.sampler.memoryHistory) : []
    }
    // Swap rides along as its own line: it is a different kind of pressure
    // from RAM, and it is absent entirely when nothing is swapped.
    secondary: {
      void root.revisionTick
      return root.sampler ? Engine.ringValues(root.sampler.swapHistory) : []
    }
    secondaryStroke: Color.urgent
    revision: root.sampler ? root.sampler.revision : 0
  }

  MeterRow {
    Layout.fillWidth: true
    label: "Used"
    value: Format.formatKB(root.usedKB) + " of " + Format.formatKB(root.totalKB)
    ratio: isNaN(root.percent) ? NaN : root.percent / 100
    urgent: !isNaN(root.percent) && root.percent >= 90
  }

  MeterRow {
    Layout.fillWidth: true
    label: "Available"
    value: Format.formatKB(root.availableKB)
    ratio: (isNaN(root.availableKB) || isNaN(root.totalKB) || root.totalKB <= 0)
      ? NaN : root.availableKB / root.totalKB
  }

  MeterRow {
    Layout.fillWidth: true
    label: "Cached"
    value: Format.formatKB(root.cachedKB)
    ratio: (isNaN(root.cachedKB) || isNaN(root.totalKB) || root.totalKB <= 0)
      ? NaN : root.cachedKB / root.totalKB
  }

  MeterRow {
    Layout.fillWidth: true
    label: "Buffers"
    value: Format.formatKB(root.buffersKB)
    ratio: (isNaN(root.buffersKB) || isNaN(root.totalKB) || root.totalKB <= 0)
      ? NaN : root.buffersKB / root.totalKB
  }

  MeterRow {
    Layout.fillWidth: true
    visible: root.swapTotalKB > 0
    label: "Swap"
    value: Format.formatKB(root.swapUsedKB) + " of " + Format.formatKB(root.swapTotalKB)
    ratio: (isNaN(root.swapUsedKB) || isNaN(root.swapTotalKB) || root.swapTotalKB <= 0)
      ? NaN : root.swapUsedKB / root.swapTotalKB
  }
}

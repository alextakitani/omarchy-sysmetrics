import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format
import "../js/engine.js" as Engine

DetailSection {
  id: root

  property QtObject sampler: null
  // Re-read the rings whenever a new sample lands.
  readonly property int revisionTick: sampler ? sampler.revisionOf("cpu") : 0

  // sampler is injected after this item is created, so every read guards
  // against it still being null.
  readonly property real cpuUsage: sampler ? sampler.cpuUsage : NaN
  readonly property real cpuAggregate: sampler ? sampler.cpuAggregate : NaN
  readonly property var cpuCores: sampler ? sampler.cpuCores : []
  readonly property var loadAverage: sampler ? sampler.loadAverage : null

  title: "Processor · busiest core"
  headline: Format.formatPercent(cpuUsage)

  DetailChart {
    Layout.fillWidth: true
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      return root.sampler ? Engine.ringValues(root.sampler.cpuHistory) : []
    }
    revision: root.revisionTick
    stroke: !isNaN(root.cpuUsage) && root.cpuUsage >= 90 ? Color.urgent : Color.accent
  }

  CoreGrid {
    Layout.fillWidth: true
    cores: root.cpuCores
  }

  // The headline is the busiest core, so the mean across all of them is
  // shown here rather than lost -- they answer different questions and the
  // gap between them is the interesting part on a many-core machine.
  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(4)

    Text {
      text: "All cores"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      Layout.fillWidth: true
      horizontalAlignment: Text.AlignRight
      text: Format.formatPercent(root.cpuAggregate)
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(4)

    Text {
      text: "Load"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      Layout.fillWidth: true
      horizontalAlignment: Text.AlignRight
      text: {
        var l = root.loadAverage
        if (!l) return Format.DASH + " · " + Format.DASH + " · " + Format.DASH
        var one = isNaN(l.one) ? Format.DASH : l.one.toFixed(2)
        var five = isNaN(l.five) ? Format.DASH : l.five.toFixed(2)
        var fifteen = isNaN(l.fifteen) ? Format.DASH : l.fifteen.toFixed(2)
        return one + " · " + five + " · " + fifteen
      }
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}

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
  readonly property string cpuModel: sampler ? sampler.cpuModel : ""
  readonly property real cpuFrequencyKhz: sampler ? sampler.cpuFrequencyKhz : NaN
  // The aggregate row states what btop's CPU header states in one line: the
  // package temperature and the CPU's power alongside the load. Both come from
  // their own sections' readings, and either may be missing on a machine
  // without the sensor (RAPL is root-only, so CPU power often is).
  readonly property real temperature: sampler ? sampler.temperature : NaN
  readonly property real cpuPower: sampler ? sampler.cpuPower : NaN
  readonly property real urgentAt: sampler ? sampler.config.cpu.urgent : 90
  readonly property bool aggregateUrgent: !isNaN(cpuAggregate) && cpuAggregate >= urgentAt

  title: sampler && sampler.config.cpu.reading === "average"
    ? "Processor · average"
    : "Processor · busiest core"
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

  // Chip name and current frequency: the header btop prints above its CPU box.
  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(6)

    Text {
      Layout.fillWidth: true
      text: Format.formatCpuModel(root.cpuModel)
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      text: Format.formatGhz(root.cpuFrequencyKhz)
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      horizontalAlignment: Text.AlignRight
    }
  }

  // The aggregate row: "CPU", the load bar, the mean across every core, then
  // the package temperature and power. The bar is a smooth track, not btop's
  // block glyphs -- this is a GUI card, and a filled bar is this widget's own
  // language for the same reading.
  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(6)

    Text {
      text: "CPU"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      id: aggregateTrack
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      Layout.preferredHeight: Style.space(3)
      radius: height / 2
      color: Util.alpha(Color.muted, 0.3)

      Rectangle {
        height: parent.height
        radius: parent.radius
        // No reading renders no fill at all, not a misleading 0%.
        width: isNaN(root.cpuAggregate)
          ? 0
          : aggregateTrack.width * Math.max(0, Math.min(1, root.cpuAggregate / 100))
        color: root.aggregateUrgent ? Color.urgent : Color.accent
      }
    }

    Text {
      text: Format.formatPercent(root.cpuAggregate)
      color: root.aggregateUrgent ? Color.urgent : Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      // Reserved at its widest so the row does not shuffle as values change.
      Layout.preferredWidth: aggregateMetrics.advanceWidth
      TextMetrics {
        id: aggregateMetrics
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        text: "100%"
      }
    }

    Text {
      text: Format.formatTempShort(root.temperature)
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      Layout.preferredWidth: tempMetrics.advanceWidth
      TextMetrics {
        id: tempMetrics
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        text: "888°"
      }
    }

    Text {
      text: Format.formatWatts(root.cpuPower)
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      Layout.preferredWidth: wattMetrics.advanceWidth
      TextMetrics {
        id: wattMetrics
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        text: "888W"
      }
    }
  }

  CoreGrid {
    Layout.fillWidth: true
    cores: root.cpuCores
    histories: root.sampler ? root.sampler.cpuCoreHistory : []
    revision: root.revisionTick
    urgentAt: root.urgentAt
  }

  // The last line of btop's box, and the one reading the aggregate still
  // carries on a machine with no per-core sensors to look at.
  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(4)

    Text {
      text: "Load avg"
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

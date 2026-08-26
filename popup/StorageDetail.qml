import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format
import "../js/engine.js" as Engine

// Filesystem capacity — how full the disks are, which is a different question
// from how busy they are (that is Disk I/O). One row per distinct filesystem,
// largest first.
DetailSection {
  id: root

  property QtObject sampler: null
  readonly property int revisionTick: sampler ? sampler.revisionOf("storage") : 0

  readonly property var filesystems: {
    void revisionTick
    return sampler ? sampler.filesystems : []
  }
  readonly property real percent: sampler ? sampler.storagePercent : NaN

  title: "Storage"
  headline: Format.formatPercent(percent)

  Repeater {
    model: root.filesystems

    delegate: MeterRow {
      required property var modelData

      Layout.fillWidth: true
      label: modelData.target
      value: Format.formatBytes(modelData.usedBytes) + " of " + Format.formatBytes(modelData.sizeBytes)
      ratio: isNaN(modelData.percent) ? NaN : modelData.percent / 100
      // A filesystem over 90% is a real problem, not a curiosity.
      urgent: modelData.percent >= 90
    }
  }

  MeterRow {
    Layout.fillWidth: true
    visible: !root.filesystems || root.filesystems.length === 0
    label: "Filesystems"
    value: Format.DASH
    ratio: NaN
  }
}

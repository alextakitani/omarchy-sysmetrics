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

  readonly property real diskRead: sampler ? sampler.diskRead : NaN
  readonly property real diskWrite: sampler ? sampler.diskWrite : NaN
  readonly property var diskDevices: sampler ? sampler.diskDevices : ({})

  // Flatten the devices dictionary into an array once per update so the
  // Repeater below has a stable indexable model instead of iterating keys
  // in a delegate.
  readonly property var deviceModel: {
    var devices = root.diskDevices || {}
    var names = Object.keys(devices)
    var list = []
    for (var i = 0; i < names.length; i++) {
      var name = names[i]
      var d = devices[name] || {}
      list.push({ name: name, read: d.read, write: d.write })
    }
    return list
  }

  title: "Disk I/O"
  headline: (isNaN(root.diskRead) || isNaN(root.diskWrite))
    ? Format.DASH
    : Format.formatRateFull(root.diskRead + root.diskWrite)

  // Mirrored: the first direction above the centre line, the second below.
  // Merged into one line the two would lose direction, which is half of what
  // the metric says. Both share one scale so they stay comparable.
  DetailChart {
    Layout.fillWidth: true
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      return root.sampler ? Engine.ringValues(root.sampler.diskReadHistory) : []
    }
    secondary: {
      void root.revisionTick
      return root.sampler ? Engine.ringValues(root.sampler.diskWriteHistory) : []
    }
    mode: "mirror"
    // Same hue-rotated counterpart the bar uses, so the two surfaces
    // agree on which direction is which.
    secondaryStroke: Qt.hsla((Color.accent.hslHue + 0.42) % 1.0,
                             Math.min(1, Color.accent.hslSaturation * 1.15),
                             Color.accent.hslLightness, 1)
    ceiling: root.sampler
      ? Engine.rollingCeiling([Engine.ringValues(root.sampler.diskReadHistory),
                               Engine.ringValues(root.sampler.diskWriteHistory)], 1048576)
      : 1048576
    revision: root.sampler ? root.sampler.revision : 0
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(4)

    Text {
      Layout.fillWidth: true
      text: "Read"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      text: Format.formatRateFull(root.diskRead)
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(4)

    Text {
      Layout.fillWidth: true
      text: "Write"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      text: Format.formatRateFull(root.diskWrite)
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  Repeater {
    model: root.deviceModel

    delegate: RowLayout {
      id: deviceRow
      required property var modelData

      Layout.fillWidth: true
      spacing: Style.space(4)

      Text {
        Layout.fillWidth: true
        text: deviceRow.modelData.name
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        text: "R " + Format.formatRateFull(deviceRow.modelData.read)
          + " · W " + Format.formatRateFull(deviceRow.modelData.write)
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}

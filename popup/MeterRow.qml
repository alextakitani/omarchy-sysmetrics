import QtQuick
import QtQuick.Layouts
import qs.Commons

// Labelled horizontal meter: a label/value row on top, a thin filled track
// below. Used for anything expressed as "some quantity out of a bound"
// (memory, VRAM, per-core load, temperature range).
ColumnLayout {
  id: root

  property string label: ""
  property string value: ""
  property real ratio: NaN
  property bool urgent: false

  readonly property bool hasRatio: !isNaN(ratio)
  // Clamp defensively: callers compute ratio from live samples, which can
  // transiently exceed [0, 1] (e.g. a rounding blip on 100% usage).
  readonly property real clampedRatio: hasRatio ? Math.max(0, Math.min(1, ratio)) : 0

  spacing: Style.space(2)

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(4)

    Text {
      Layout.fillWidth: true
      text: root.label
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      text: root.value
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  Rectangle {
    id: track
    Layout.fillWidth: true
    height: Style.space(1)
    radius: height / 2
    color: Util.alpha(Color.muted, 0.3)

    Rectangle {
      height: parent.height
      radius: parent.radius
      // Zero width (NaN ratio) renders no fill at all, not a misleading 0%.
      width: root.hasRatio ? track.width * root.clampedRatio : 0
      color: root.urgent ? Color.urgent : Color.accent
    }
  }
}

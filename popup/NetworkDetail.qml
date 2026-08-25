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

  readonly property string interfaceName: sampler ? sampler.networkInterface : ""
  readonly property real rx: sampler ? sampler.networkRx : NaN
  readonly property real tx: sampler ? sampler.networkTx : NaN

  title: "Network"
  headline: root.interfaceName.length > 0 ? root.interfaceName : Format.DASH

  // Rates are unbounded (no natural ceiling), so plain label/value rows
  // instead of MeterRow -- a meter would imply a maximum that doesn't exist.
  // Mirrored: the first direction above the centre line, the second below.
  // Merged into one line the two would lose direction, which is half of what
  // the metric says. Both share one scale so they stay comparable.
  DetailChart {
    Layout.fillWidth: true
    primary: {
      void root.revisionTick        // in-place ring mutation is invisible to bindings
      return root.sampler ? Engine.ringValues(root.sampler.networkRxHistory) : []
    }
    secondary: {
      void root.revisionTick
      return root.sampler ? Engine.ringValues(root.sampler.networkTxHistory) : []
    }
    mode: "mirror"
    // Same hue-rotated counterpart the bar uses, so the two surfaces
    // agree on which direction is which.
    secondaryStroke: Qt.hsla((Color.accent.hslHue + 0.42) % 1.0,
                             Math.min(1, Color.accent.hslSaturation * 1.15),
                             Color.accent.hslLightness, 1)
    ceiling: root.sampler
      ? Engine.rollingCeiling([Engine.ringValues(root.sampler.networkRxHistory),
                               Engine.ringValues(root.sampler.networkTxHistory)], 65536)
      : 65536
    revision: root.sampler ? root.sampler.revision : 0
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(4)

    Text {
      Layout.fillWidth: true
      text: "Download"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      text: Format.formatRateFull(root.rx)
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
      text: "Upload"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      text: Format.formatRateFull(root.tx)
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}

import QtQuick
import QtQuick.Layouts
import qs.Commons
import ".." as Root
import "../js/format.js" as Format
import "../js/engine.js" as Engine

// One core of the CPU box: "C<n> <history graph> <percent>", the row btop
// draws. The graph is the core's own recent history, not a static leader --
// at a glance it says whether a core is quiet, spiky, or pinned, which the
// instantaneous percentage cannot.
//
// No per-core temperature: the package sensor is the only one this machine
// exposes, so repeating it down every row would state one reading sixteen
// times.
RowLayout {
  id: root

  property int coreIndex: 0
  property real pct: NaN
  property var history: null
  property int revision: 0
  property bool urgent: false

  Layout.fillWidth: true
  spacing: Style.space(3)

  Text {
    // "C0".."C15", reserved at the two-digit width so single-digit cores end
    // flush with the rest of the column instead of shifting the graph.
    text: "C" + root.coreIndex
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    Layout.preferredWidth: labelMetrics.advanceWidth
    TextMetrics {
      id: labelMetrics
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      text: "C88"
    }
  }

  // The per-core history. One small canvas per core: unlike a filled bar,
  // which is two rectangles, a graph genuinely needs drawing, and at this size
  // the emphasis curve would exaggerate an idle core, so the true proportions
  // are left alone.
  Root.Sparkline {
    Layout.fillWidth: true
    Layout.preferredHeight: Style.space(10)
    Layout.alignment: Qt.AlignVCenter
    primary: {
      void root.revision        // in-place ring mutation is invisible to bindings
      return root.history ? Engine.ringValues(root.history) : []
    }
    revision: root.revision
    ceiling: 100
    mode: "area"
    emphasizeLowLoad: false
    stroke: root.urgent ? Color.urgent : Color.accent
  }

  Text {
    text: Format.formatPercent(root.pct)
    color: root.urgent ? Color.urgent : Color.accent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignRight
    // Reserved at its widest so the column does not shift as values change.
    Layout.preferredWidth: pctMetrics.advanceWidth
    TextMetrics {
      id: pctMetrics
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      text: "100%"
    }
  }
}

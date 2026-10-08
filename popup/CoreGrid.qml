import QtQuick
import QtQuick.Layouts
import qs.Commons

// Live per-core usage as two columns: the first half of the cores down the
// left, the second half down the right. That is the shape btop draws, so a
// sixteen-core machine is read eight rows at a time rather than as one long
// list. Each row is a CoreRow.
RowLayout {
  id: root

  property var cores: []
  property var histories: []
  property int revision: 0
  property real urgentAt: 90

  readonly property int count: cores ? cores.length : 0
  readonly property int splitAt: Math.ceil(count / 2)

  // The Repeater's model is the *indices*, which only change when the core
  // count does. The per-core values are read through properties on each row
  // instead, so a new sample updates the sixteen rows rather than tearing
  // down and rebuilding sixteen delegates (and their graphs) every tick.
  function indexRange(from, to) {
    var out = []
    for (var i = from; i < to && i < root.count; i++) out.push(i)
    return out
  }

  readonly property var leftIndices: indexRange(0, splitAt)
  readonly property var rightIndices: indexRange(splitAt, count)

  spacing: Style.space(10)

  ColumnLayout {
    Layout.fillWidth: true
    // Equal to the right column's, so the layout gives the two an even split
    // rather than sizing each to its own content.
    Layout.preferredWidth: 1
    spacing: Style.space(2)

    Repeater {
      model: root.leftIndices
      delegate: CoreRow {
        required property var modelData
        coreIndex: modelData
        pct: root.cores[modelData]
        history: root.histories[modelData]
        revision: root.revision
        urgent: !isNaN(pct) && pct >= root.urgentAt
      }
    }
  }

  ColumnLayout {
    Layout.fillWidth: true
    Layout.preferredWidth: 1
    spacing: Style.space(2)

    Repeater {
      model: root.rightIndices
      delegate: CoreRow {
        required property var modelData
        coreIndex: modelData
        pct: root.cores[modelData]
        history: root.histories[modelData]
        revision: root.revision
        urgent: !isNaN(pct) && pct >= root.urgentAt
      }
    }
  }
}

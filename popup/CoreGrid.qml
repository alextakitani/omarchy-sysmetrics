import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format

// Compact grid of per-core usage cells, roughly square (e.g. 16 cores -> 4x4).
// Deliberately plain Rectangles rather than one Canvas per core: Canvas
// repaint is per-item overhead that buys nothing here since a filled bar is
// just two rectangles that bind for free.
GridLayout {
  id: root

  property var cores: []

  columns: Math.max(1, Math.ceil(Math.sqrt(cores.length)))
  rowSpacing: Style.space(2)
  columnSpacing: Style.space(7)

  Repeater {
    model: root.cores

    delegate: ColumnLayout {
      id: cell
      required property var modelData
      required property int index

      readonly property real pct: modelData
      readonly property bool hasPct: !isNaN(pct)
      readonly property bool isUrgent: hasPct && pct >= 90

      Layout.fillWidth: true
      // Without a floor the four columns squeeze until the core index and its
      // percentage collide into one unreadable run of digits.
      Layout.minimumWidth: Style.space(19)
      spacing: Style.space(1)

      RowLayout {
        Layout.fillWidth: true
        // Index and value are one reading, so they sit together on the left
        // with the slack pushed to the right of the pair. Spreading them to
        // the cell's two edges put each value nearer the next core's index
        // than its own, and the eye grouped them wrongly.
        spacing: Style.space(2)

        Text {
          // Chip glyph (U+F4BC) and the core number are one label, so they
          // live in a single Text: as separate items the number was aligned
          // to the right of its own reserved box and drifted away from the
          // glyph. Escaped rather than written literally so the glyph
          // survives being edited through a shell heredoc.
          text: "\uF4BC " + cell.index
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          // Reserved at the two-digit width so single-digit cores line up
          // with the rest of the column instead of shifting left.
          Layout.preferredWidth: indexMetrics.advanceWidth
          TextMetrics {
            id: indexMetrics
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            text: "\uF4BC 88"
          }
        }

        Item { Layout.fillWidth: true }

        Text {
          text: Format.formatPercent(cell.pct)
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
          // Reserved at its widest so the column does not shift as values
          // change width.
          Layout.preferredWidth: pctMetrics.advanceWidth
          TextMetrics {
            id: pctMetrics
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            text: "100%"
          }
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
          width: cell.hasPct ? track.width * Math.max(0, Math.min(1, cell.pct / 100)) : 0
          color: cell.isUrgent ? Color.urgent : Color.accent
        }
      }
    }
  }
}

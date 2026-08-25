import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Reusable frame for one metric section of the popup: an optional separator,
// a header row (title left, current-value headline right), then arbitrary
// content below. Every *Detail.qml wraps its body in one of these so the
// popup reads as a consistent list of sections.
ColumnLayout {
  id: root

  property string title: ""
  property string headline: ""
  property bool showSeparator: true
  // Which metric this section governs, and whether it is currently pinned to
  // the bar. Set both to make the header a toggle.
  property string metricId: ""
  property bool pinned: false
  signal pinToggled()
  property bool headerHovered: false
  default property alias content: contentColumn.children

  // Between the section's own parts (separator, header, content).
  spacing: Style.space(7)

  PanelSeparator {
    Layout.fillWidth: true
    visible: root.showSeparator
  }

  // The header row doubles as the toggle's hit area. The MouseArea is the
  // layout item itself, so the labels inside it stay laid out normally and no
  // anchors are placed on anything a layout manages.
  MouseArea {
    id: headerMouse
    Layout.fillWidth: true
    implicitHeight: headerRow.implicitHeight
    Layout.preferredHeight: implicitHeight
    enabled: root.metricId !== ""
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton
    onClicked: root.pinToggled()
    onContainsMouseChanged: root.headerHovered = containsMouse

  RowLayout {
    id: headerRow
    // Width follows the hit area; height is the row's own, so the two do not
    // define each other.
    width: parent.width
    spacing: Style.space(4)

    // A filled dot means the metric is on the bar, a hollow one means it is
    // only in this popup. Clicking anywhere on the header row flips it.
    Rectangle {
      visible: root.metricId !== ""
      implicitWidth: Style.space(7)
      implicitHeight: Style.space(7)
      radius: width / 2
      color: root.pinned ? Color.accent : "transparent"
      border.width: root.pinned ? 0 : 1
      border.color: Util.alpha(Color.muted, 0.7)
      opacity: root.headerHovered ? 1 : 0.85
    }

    PanelSectionHeader {
      Layout.fillWidth: true
      text: root.title
      foreground: root.headerHovered && root.metricId !== ""
        ? Color.accent
        : Color.foreground
    }

    Text {
      text: root.headline
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
    }
  }
  }

  ColumnLayout {
    id: contentColumn
    Layout.fillWidth: true
    // Tightest gap: these rows belong together.
    spacing: Style.space(5)
  }
}

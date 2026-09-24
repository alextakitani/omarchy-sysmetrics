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

  // Whether this section's reading goes into a recording. Independent of the
  // pin: what you watch on the bar and what you want on disk for later are
  // different questions. Any section with a metric can be logged; the process
  // lists opt in by setting `loggable` themselves.
  property bool loggable: metricId !== ""
  property bool logged: false
  signal logToggled()
  default property alias content: contentColumn.children

  // Collapsible sections carry a disclosure caret instead of a pin dot, and
  // their content is hidden until asked for. A section is one or the other:
  // the header row is a single hit area, so it cannot both pin and expand.
  // Set `collapsible` to make this section's header a disclosure toggle.
  property bool collapsible: false
  property bool expanded: false

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
    enabled: root.collapsible || root.metricId !== ""
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton
    onClicked: {
      if (root.collapsible) root.expanded = !root.expanded
      else root.pinToggled()
    }
    onContainsMouseChanged: root.headerHovered = containsMouse

    // What a click on the heading does. Not over the log marker, which has
    // its own hint.
    PanelToolTip {
      visible: headerMouse.containsMouse && !logMouse.containsMouse
               && (root.collapsible || root.metricId !== "")
      text: root.collapsible
        ? (root.expanded ? "Hide the list" : "Show the list")
        : (root.pinned ? "Remove from the bar" : "Show on the bar")
    }

  RowLayout {
    id: headerRow
    // Width follows the hit area; height is the row's own, so the two do not
    // define each other.
    width: parent.width
    spacing: Style.space(4)

    // A filled dot means the metric is on the bar, a hollow one means it is
    // only in this popup. Clicking anywhere on the header row flips it.
    Rectangle {
      visible: !root.collapsible && root.metricId !== ""
      implicitWidth: Style.space(7)
      implicitHeight: Style.space(7)
      radius: width / 2
      color: root.pinned ? Color.accent : "transparent"
      border.width: root.pinned ? 0 : 1
      border.color: Util.alpha(Color.muted, 0.7)
      opacity: root.headerHovered ? 1 : 0.85
    }

    // Disclosure caret. Occupies the dot's slot so a collapsible section's
    // title lines up with every pinnable one above it.
    Text {
      visible: root.collapsible
      // Right when shut, down when open: the caret points at what the click
      // will reveal, which is the convention every file tree uses. Same
      // chevron the shell's own Dropdown uses (U+F0140), written as a
      // surrogate pair so it survives being edited through a shell heredoc,
      // as CoreGrid's glyph is.
      text: root.expanded ? "\uDB80\uDD40" : "\uDB80\uDD42"
      color: root.headerHovered ? Color.accent : Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      // Reserved at the dot's width so neither caret shifts the title.
      Layout.preferredWidth: Style.space(7)
      horizontalAlignment: Text.AlignHCenter
    }

    PanelSectionHeader {
      Layout.fillWidth: true
      text: root.title
      foreground: root.headerHovered && (root.collapsible || root.metricId !== "")
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

    // The log marker: red when this reading is recorded, a faint ring when it
    // is not. It is the one part of the header with its own hit area, so the
    // rest of the row still pins or expands. Red, and on the far side from
    // the pin dot, so the two are never mistaken for each other.
    Rectangle {
      visible: root.loggable
      Layout.leftMargin: Style.space(6)
      implicitWidth: Style.space(7)
      implicitHeight: Style.space(7)
      radius: width / 2
      color: root.logged ? Color.urgent : "transparent"
      border.width: root.logged ? 0 : 1
      border.color: logMouse.containsMouse ? Color.urgent : Util.alpha(Color.muted, 0.7)
      opacity: logMouse.containsMouse || root.logged ? 1 : 0.55

      MouseArea {
        id: logMouse
        anchors.fill: parent
        // A 7px target is too small to hit reliably; the margin widens it
        // without moving anything.
        anchors.margins: -Style.space(5)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.logToggled()
      }

      PanelToolTip {
        visible: logMouse.containsMouse
        text: root.logged ? "Stop logging this reading" : "Log this reading when recording"
      }
    }
  }
  }

  ColumnLayout {
    id: contentColumn
    Layout.fillWidth: true
    // Tightest gap: these rows belong together.
    spacing: Style.space(5)
    // A collapsed section keeps its header and separator -- it has to stay
    // clickable to come back -- and drops only its body. `visible: false` on
    // a layout item also removes it from the layout, so the popup shrinks
    // rather than leaving a gap where the content was.
    visible: !root.collapsible || root.expanded
  }
}

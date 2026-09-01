import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../js/format.js" as Format

// One row of a top-processes list: name and pid on the left, a thin bar
// giving the reading a shape, then the reading itself.
//
// Its own file rather than an inline delegate, matching MeterRow: the two are
// the same kind of thing, and a row that is a component can be measured and
// reasoned about on its own.
RowLayout {
  id: root

  property string comm: ""
  property int pid: 0
  property real reading: NaN
  // What the bar measures the reading against: one core for CPU (which a
  // threaded process may exceed), total RAM for memory.
  property real ceiling: 100
  property bool bytes: false

  readonly property real ratio: (isNaN(reading) || !(ceiling > 0))
    ? NaN
    : reading / ceiling

  spacing: Style.space(4)

  // Name and pid are one label, in one item: the pid identifies WHICH of the
  // eight chrome rows this is, so it belongs against the name rather than in
  // a column of its own. Given its own right-aligned column at the caption
  // size it read as a second measurement competing with the percentage --
  // which is what it looked like, and got asked about.
  //
  // Kept as two Text items so the pid can be smaller and dimmer than the
  // name, but packed tight and left-aligned so they read as one thing.
  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(3)

    Text {
      // PlainText, not AutoText: `comm` is a string the kernel accepted from
      // whoever spawned the process, so a name containing markup has to
      // render as that name rather than as rich text.
      textFormat: Text.PlainText
      text: root.comm
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      // The name yields first when the row is tight: a truncated name is
      // still recognisable, and the pid is only four or five glyphs.
      Layout.maximumWidth: root.width * 0.55
    }

    Text {
      text: root.pid
      // Dimmer and a size down: an identifier you read only when two rows
      // share a name, not a number to scan down the list.
      color: Util.alpha(Color.muted, 0.55)
      font.family: Style.font.family
      font.pixelSize: Math.max(1, Style.font.caption - 1)
      // Baseline-aligned with the name rather than centred, so the two sit on
      // one line the way a name and its suffix do.
      Layout.alignment: Qt.AlignBaseline
    }

    // Takes the slack, so the pair stays packed against the name instead of
    // spreading across the row.
    Item { Layout.fillWidth: true }
  }

  // A shape for the number beside it, not a control: narrow, so the reading
  // stays the thing being read.
  Rectangle {
    id: track
    Layout.preferredWidth: Style.space(40)
    // Layout.preferredHeight, not height: a RowLayout drives its children's
    // geometry, and a plain `height` on one of them fights it.
    Layout.preferredHeight: Style.space(1)
    Layout.alignment: Qt.AlignVCenter
    radius: height / 2
    color: Util.alpha(Color.muted, 0.3)

    Rectangle {
      height: track.height
      radius: parent.radius
      // No reading renders no fill at all, rather than a misleading zero.
      width: isNaN(root.ratio)
        ? 0
        : track.width * Math.max(0, Math.min(1, root.ratio))
      color: Color.accent
    }
  }

  Text {
    text: root.bytes
      ? Format.formatBytes(root.reading)
      : Format.formatPercent(root.reading)
    color: Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignRight
    Layout.preferredWidth: readingMetrics.advanceWidth
    TextMetrics {
      id: readingMetrics
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      // Widest each column gets: a threaded process passes 100%, and memory
      // reaches "888.8 GiB".
      text: root.bytes ? "888.8 GiB" : "8888%"
    }
  }
}

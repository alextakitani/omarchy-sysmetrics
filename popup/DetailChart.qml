import QtQuick
import QtQuick.Layouts
import qs.Commons
import ".." as Root

// History plot for a popup section. Thin wrapper over the shared Sparkline so
// the popup and the bar cannot drift apart: a metric drawn as mirrored
// columns in the bar must not become a filled area here, or the same data
// would carry two different claims.
Item {
  id: root

  property var primary: []
  property var secondary: []
  property real ceiling: 100
  property real floorValue: 0
  property string mode: "area"
  property color stroke: Color.accent
  property color secondaryStroke: stroke
  property real urgentAt: NaN
  property bool showThreshold: false
  property int revision: 0
  // The bar's low-load emphasis exists to rescue a 14px gauge; with this much
  // height the true proportions are legible, so the curve is left undistorted.
  property bool emphasizeLowLoad: false

  implicitHeight: Style.space(34)
  Layout.preferredHeight: implicitHeight
  Layout.fillWidth: true
  // The plot is a block, not a row: it needs more air beneath it than the
  // label rows need between themselves, or it reads as fused to the first one.
  Layout.bottomMargin: Style.space(3)

  Root.Sparkline {
    anchors.fill: parent
    primary: root.primary
    secondary: root.secondary
    ceiling: root.ceiling
    floorValue: root.floorValue
    mode: root.mode
    stroke: root.stroke
    secondaryStroke: root.secondaryStroke
    urgentAt: root.urgentAt
    showThreshold: root.showThreshold
    revision: root.revision
    emphasizeLowLoad: root.emphasizeLowLoad
  }
}

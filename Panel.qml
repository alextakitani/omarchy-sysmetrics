import QtQuick
import qs.Commons
import qs.Ui as Ui
import "popup" as Detail
import "js/format.js" as Format

// Detail popup: one section per enabled metric, in the order the user
// configured them. The heavy reading (per-core load, VRAM, load average) is
// gated on this panel being open — the Sampler watches `popupOpen`.
Ui.Panel {
  id: root
  moduleName: "takitani.sysmetrics"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property QtObject sampler: null
  readonly property var barIdentity: hostWidget || root

  readonly property var metrics: sampler ? sampler.config.metrics : []

  function hasMetric(id) {
    return metrics.indexOf(id) >= 0
  }

  // Every section is shown whether or not its metric is on the bar: the popup
  // is where the strip is configured, so a metric you have hidden still has
  // to be reachable to bring back.
  readonly property var sectionOrder: ["cpu", "cputemp", "memory", "gpu", "vram", "gputemp", "storage", "network", "disk"]

  // The first section skips its separator, so the popup does not open with a
  // rule floating above its first heading.
  function isFirstVisible(id) {
    return sectionOrder.length > 0 && sectionOrder[0] === id
  }

  // Sticky mode: while set, the popup ignores the dismissals it would
  // normally obey (a click outside, Escape, the bar switching panels), so it
  // can be left open beside whatever the user is actually doing. The pin
  // itself and an explicit toggle from the widget still close it — otherwise
  // there would be no way out.
  property bool sticky: false

  // Published so the widget can size its anchor marker: the popup is anchored
  // by its right edge, which needs to know how wide the card is.
  readonly property real cardWidth: panel ? panel.contentWidth : 0

  function close() {
    if (sticky) return
    controller.hide()
  }

  // Bypasses the sticky guard, for the paths that must always work.
  function forceClose() {
    sticky = false
    controller.hide()
  }

  function toggle() {
    if (opened) forceClose()
    else open()
  }

  function closeForPopoutSwitch() {
    if (sticky) return
    popoutSwitchClosing = true
    controller.hide()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }

  // Poll interval, adjustable from the popup. Clamped to the same range the
  // config normaliser enforces, so a click can never write a value the
  // normaliser would silently replace.
  function stepInterval(delta) {
    if (!hostWidget || typeof hostWidget.setInterval !== "function") return
    var current = sampler ? sampler.config.intervalMs : 2000
    hostWidget.setInterval(current + delta)
  }

  function togglePin(id) {
    if (hostWidget && typeof hostWidget.toggleMetric === "function")
      hostWidget.toggleMetric(id)
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: parent.width
          // Largest gap in the popup: this is what separates one metric
          // from the next, and it has to beat the spacing inside them.
          spacing: Style.space(14)

          // Title row carrying the sticky pin. Sits above the first section
          // so the pin has a fixed home regardless of which metrics exist.
          Item {
            width: parent.width
            height: Math.max(titleBlock.implicitHeight, pinButton.height)

            Column {
              id: titleBlock
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "System metrics"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                text: root.sampler
                  ? "up " + Format.formatUptime(root.sampler.uptimeSeconds)
                  : Format.DASH
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              anchors.right: pinButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "refresh"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: [{ label: "\u2212", delta: -500 }, { label: "+", delta: 500 }]

                delegate: Rectangle {
                  required property var modelData
                  width: Style.space(16)
                  height: Style.space(16)
                  radius: Style.space(4)
                  color: stepMouse.containsMouse ? Util.alpha(Color.muted, 0.18) : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: modelData.label
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    id: stepMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.stepInterval(modelData.delta)
                  }
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.sampler ? (root.sampler.config.intervalMs + " ms") : Format.DASH
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              id: pinButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(20)
              height: Style.space(20)
              radius: Style.space(4)
              color: root.sticky
                ? Util.alpha(Color.accent, 0.18)
                : (pinMouse.containsMouse ? Util.alpha(Color.muted, 0.18) : "transparent")
              border.width: root.sticky ? 1 : 0
              border.color: Util.alpha(Color.accent, 0.5)

              Text {
                anchors.centerIn: parent
                // Filled pin when stuck, outlined when not: the state is
                // carried by the glyph's shape as well as by its colour.
                text: root.sticky ? "\uDB81\uDC03" : "\uDB82\uDD30"
                color: root.sticky ? Color.accent : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: pinMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.sticky = !root.sticky
              }
            }
          }

          Detail.CpuDetail {
            width: parent.width
            showSeparator: !root.isFirstVisible("cpu")
            sampler: root.sampler
            metricId: "cpu"
            pinned: root.hasMetric("cpu")
            onPinToggled: root.togglePin("cpu")
          }

          Detail.MemoryDetail {
            width: parent.width
            showSeparator: !root.isFirstVisible("memory")
            sampler: root.sampler
            metricId: "memory"
            pinned: root.hasMetric("memory")
            onPinToggled: root.togglePin("memory")
          }

          Detail.GpuDetail {
            width: parent.width
            showSeparator: !root.isFirstVisible("gpu")
            sampler: root.sampler
            metricId: "gpu"
            pinned: root.hasMetric("gpu")
            onPinToggled: root.togglePin("gpu")
          }

          Detail.VramDetail {
            width: parent.width
            showSeparator: !root.isFirstVisible("vram")
            sampler: root.sampler
            metricId: "vram"
            pinned: root.hasMetric("vram")
            onPinToggled: root.togglePin("vram")
          }

          Detail.StorageDetail {
            width: parent.width
            showSeparator: !root.isFirstVisible("storage")
            sampler: root.sampler
            metricId: "storage"
            pinned: root.hasMetric("storage")
            onPinToggled: root.togglePin("storage")
          }

          Detail.NetworkDetail {
            width: parent.width
            showSeparator: !root.isFirstVisible("network")
            sampler: root.sampler
            metricId: "network"
            pinned: root.hasMetric("network")
            onPinToggled: root.togglePin("network")
          }

          Detail.DiskDetail {
            width: parent.width
            showSeparator: !root.isFirstVisible("disk")
            sampler: root.sampler
            metricId: "disk"
            pinned: root.hasMetric("disk")
            onPinToggled: root.togglePin("disk")
          }

          Detail.TemperatureDetail {
            width: parent.width
            showSeparator: !root.isFirstVisible("cputemp")
            sampler: root.sampler
            metricId: "cputemp"
            pinned: root.hasMetric("cputemp")
            onPinToggled: root.togglePin("cputemp")
          }

          Detail.GpuTemperatureDetail {
            width: parent.width
            showSeparator: !root.isFirstVisible("gputemp")
            sampler: root.sampler
            metricId: "gputemp"
            pinned: root.hasMetric("gputemp")
            onPinToggled: root.togglePin("gputemp")
          }
        }
      }
    }
  }
}

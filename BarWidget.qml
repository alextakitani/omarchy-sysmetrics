import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "js/engine.js" as Engine
import "js/format.js" as Format
import "js/config.js" as Config

// A strip of live system gauges. Each metric the user enables becomes a small
// filled history plot with its current value beside it; clicking opens the
// detail popup.
//
// Everything is read straight from /proc and /sys, so the widget depends on no
// monitoring daemon and spawns no subprocess.
BarWidget {
  id: root
  moduleName: "takitani.sysmetrics"

  readonly property var config: Config.normalizeConfig(root.settings)

  // ---- Presentation per metric -------------------------------------------

  function iconFor(id) {
    // Escaped as UTF-16 surrogate pairs: most of these glyphs live above
    // U+FFFF, where a bare \uXXXXX escape would be misread as a 4-digit
    // escape plus a stray character, and a literal glyph does not survive
    // being written through a shell heredoc.
    if (id === "memory") return "\uEFC5"
    if (id === "network") return "\uDB80\uDE00"
    if (id === "disk") return "\uDB80\uDECA"
    if (id === "gpu") return "\uDB83\uDFB0"
    if (id === "vram") return "\uDB80\uDF5B"
    if (id === "storage") return "\uDB80\uDECA"
    if (id === "cputemp") return "\uF2C9"
    if (id === "gputemp") return "\uF2C9"
    return "\uF4BC"
  }

  function valueFor(id) {
    void sampler.revision
    if (id === "memory") return Format.formatPercent(sampler.memory.percent)
    // Both directions, not their sum: the mirrored plot beside this label
    // separates them, and a single total would throw away exactly the
    // information the plot is at pains to show.
    if (id === "network")
      return Format.formatRateCompact(sampler.networkRx) + "\u2009\u2193 "
           + Format.formatRateCompact(sampler.networkTx) + "\u2009\u2191"
    // Arrows rather than R/W letters: "0BR" read as one token, and the arrows
    // match the mirrored plot's up/down geometry directly.
    if (id === "disk")
      return Format.formatRateCompact(sampler.diskRead) + "\u2009\u2193 "
           + Format.formatRateCompact(sampler.diskWrite) + "\u2009\u2191"
    if (id === "gpu") return Format.formatPercent(sampler.gpuUsage)
    if (id === "vram") return Format.formatPercent(sampler.vramPercent)
    if (id === "storage") return Format.formatPercent(sampler.storagePercent)
    if (id === "cputemp") return Format.formatTempShort(sampler.temperature)
    if (id === "gputemp") return Format.formatTempShort(sampler.gpuTemperature)
    return Format.formatPercent(sampler.cpuUsage)
  }

  // Rates have no natural ceiling, so they scale against the tallest value in
  // the visible window, floored so an idle link does not amplify noise.
  function ceilingFor(id) {
    void sampler.revision
    if (id === "network")
      return Engine.rollingCeiling([Engine.ringValues(sampler.networkRxHistory),
                                    Engine.ringValues(sampler.networkTxHistory)],
                                   config.network.minCeiling)
    if (id === "disk")
      return Engine.rollingCeiling([Engine.ringValues(sampler.diskReadHistory),
                                    Engine.ringValues(sampler.diskWriteHistory)],
                                   config.disk.minCeiling)
    if (id === "cputemp") return config.cputemp.range[1]
    if (id === "gputemp") return config.gputemp.range[1]
    return 100
  }

  function primarySeriesFor(id) {
    void sampler.revision
    if (id === "memory") return Engine.ringValues(sampler.memoryHistory)
    if (id === "network") return Engine.ringValues(sampler.networkRxHistory)
    if (id === "disk") return Engine.ringValues(sampler.diskReadHistory)
    if (id === "gpu") return Engine.ringValues(sampler.gpuHistory)
    if (id === "vram") return Engine.ringValues(sampler.vramHistory)
    if (id === "storage") return Engine.ringValues(sampler.storageHistory)
    if (id === "cputemp") return Engine.ringValues(sampler.temperatureHistory)
    if (id === "gputemp") return Engine.ringValues(sampler.gpuTemperatureHistory)
    return Engine.ringValues(sampler.cpuHistory)
  }

  function secondarySeriesFor(id) {
    void sampler.revision
    if (id === "network") return Engine.ringValues(sampler.networkTxHistory)
    if (id === "disk") return Engine.ringValues(sampler.diskWriteHistory)
    if (id === "memory") return Engine.ringValues(sampler.swapHistory)
    return []
  }

  // Swap is a different kind of pressure from RAM, so it gets its own colour
  // rather than the muted twin the rate gauges use for their second series.
  // Both are theme tokens, so this still follows the active theme.
  // Chart form per metric. Not one shape for everything: a filled area
  // shades an area to mean "amount", so it is only honest on a zero baseline;
  // a two-directional rate loses half its meaning drawn as a single line; and
  // a reading that sits at zero much of the time invents activity when a line
  // interpolates across the gaps.
  function modeFor(id) {
    if (id === "network" || id === "disk") return "mirror"
    if (id === "cputemp" || id === "gputemp") return "line"
    if (id === "gpu") return "columns"
    return "area"
  }

  // Temperatures are plotted across the band they actually live in. Measured
  // from 0 C, an idle-to-throttle swing occupies a couple of pixels and a
  // thermal event looks like nothing at all.
  function floorFor(id) {
    if (id === "cputemp" || id === "gputemp") return config.cputemp.range[0]
    return 0
  }

  function urgentValueFor(id) {
    if (id === "cputemp") return config.cputemp.urgent
    if (id === "gputemp") return config.gputemp.urgent
    return NaN
  }

  // The second direction of a rate has to be told apart from the first, but
  // the theme offers only accent/urgent/muted — and urgent means "something is
  // wrong", which upload and write are not. The counterpart colour is derived
  // from the theme's own accent by rotating its hue, so it follows the active
  // theme instead of being a hardcoded value, and it keeps the same saturation
  // and lightness so both directions read as equals rather than one looking
  // disabled.
  readonly property color counterpartAccent: {
    var base = Color.accent
    var sat = base.hslSaturation
    var light = base.hslLightness
    // A near-monochrome theme has no hue to rotate, so separate by lightness.
    if (sat < 0.12)
      return Qt.hsla(base.hslHue, sat,
                     light > 0.5 ? Math.max(0, light - 0.3) : Math.min(1, light + 0.3), 1)
    return Qt.hsla((base.hslHue + 0.42) % 1.0, Math.min(1, sat * 1.15), light, 1)
  }

  // Swap keeps the urgent colour: unlike upload or write, swap in use really
  // is a warning rather than just the other direction of the same thing.
  function secondaryColorFor(id) {
    if (id === "memory") return Color.urgent
    if (id === "network" || id === "disk") return counterpartAccent
    return colorFor(id)
  }

  function isUrgent(id) {
    void sampler.revision
    if (id === "cpu") return sampler.cpuUsage >= config.cpu.urgent
    if (id === "memory") return sampler.memory.percent >= config.memory.urgent
    if (id === "gpu") return sampler.gpuUsage >= config.gpu.urgent
    if (id === "vram") return sampler.vramPercent >= config.vram.urgent
    if (id === "storage") return sampler.storagePercent >= config.storage.urgent
    if (id === "cputemp") return sampler.temperature >= config.cputemp.urgent
    if (id === "gputemp") return sampler.gpuTemperature >= config.gputemp.urgent
    return false                       // rates have no meaningful threshold
  }

  function colorFor(id) {
    return isUrgent(id) ? Color.urgent : Color.accent
  }

  // Which physical thing a metric describes. Gauges for the same device sit
  // together, so the strip reads as "here is the CPU, here is the GPU" rather
  // than as a flat run of unrelated numbers.
  function deviceFor(id) {
    if (id === "cpu" || id === "cputemp" || id === "memory") return "cpu"
    if (id === "gpu" || id === "vram" || id === "gputemp") return "gpu"
    return "io"
  }

  // True when this gauge opens a new device group, i.e. the gauge before it
  // belonged to a different device.
  function startsGroup(index) {
    if (index <= 0) return false
    return deviceFor(config.metrics[index]) !== deviceFor(config.metrics[index - 1])
  }

  function labelTemplateFor(id) {
    if (id === "network" || id === "disk")
      return "888M\u2009\u2193 888M\u2009\u2191"
    if (id === "cputemp" || id === "gputemp") return "100\u00b0"
    return "100%"
  }

  // ---- Metric visibility -------------------------------------------------
  // Toggled from the popup, so the strip is configured by clicking the thing
  // you want rather than by editing shell.json. The write goes back through
  // the bar, which is what owns the file.

  function metricEnabled(id) {
    return config.metrics.indexOf(id) >= 0
  }

  function setInterval(ms) {
    var clamped = Math.max(500, Math.min(15000, Math.round(ms / 500) * 500))
    if (clamped === config.intervalMs) return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.intervalMs = clamped
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleMetric(id) {
    var next = []
    var found = false
    // Rebuilt in the canonical order rather than by appending, so toggling a
    // metric off and on again puts it back where it belongs in the strip
    // instead of at the end.
    for (var i = 0; i < Config.METRIC_IDS.length; i++) {
      var candidate = Config.METRIC_IDS[i]
      var on = metricEnabled(candidate)
      if (candidate === id) {
        found = true
        on = !on
      }
      if (on) next.push(candidate)
    }
    if (!found) return

    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.metrics = next

    // Applied locally first so the strip reacts on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---- Sampling ----------------------------------------------------------

  Sampler {
    id: sampler
    config: root.config
    popupOpen: root.opened
  }

  Readers {
    id: readers
    sampler: sampler
  }

  Timer {
    interval: root.config.intervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: readers.sampleAll()
  }

  // ---- Popup wiring ------------------------------------------------------
  // Shape contract for Bar.findPanelWidget: open/close/opened on the root.

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = popupAnchor
    if ("hostWidget" in target) target.hostWidget = root
    if ("sampler" in target) target.sampler = sampler
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    visible: false
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // ---- Layout ------------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: strip.visible ? strip.implicitWidth : button.labelWidth

  readonly property real plotHeight: Math.max(9, Math.round(button.fontSize * 1.05))

  TextMetrics {
    id: spaceMetrics
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    text: " "
  }

  // With every metric switched off the strip would collapse to nothing and
  // the widget would become an invisible, unclickable sliver — no way back to
  // the popup that turns metrics on again. A placeholder glyph keeps it
  // present and clickable.
  Text {
    id: placeholder
    anchors.centerIn: parent
    visible: root.config.metrics.length === 0
    text: "\uF4BC"
    color: Qt.rgba(Color.bar.text.r, Color.bar.text.g, Color.bar.text.b, 0.55)
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    renderType: Text.NativeRendering
  }

  Row {
    id: strip
    anchors.centerIn: parent
    spacing: 0
    visible: root.config.metrics.length > 0 && !(root.bar && root.bar.vertical)

    Repeater {
      model: root.config.metrics

      Row {
        id: gauge
        required property var modelData
        required property int index
        spacing: spaceMetrics.advanceWidth * 0.7

        // Wider gap where the device changes, narrower between gauges that
        // describe the same device.
        leftPadding: gauge.index === 0
          ? 0
          : spaceMetrics.advanceWidth * (root.startsGroup(gauge.index) ? 3.0 : 1.4)

        // Spacing alone was too weak a signal at this size, so a device
        // boundary also gets a hairline rule.
        Rectangle {
          visible: root.startsGroup(gauge.index)
          width: 1
          height: Math.round(root.plotHeight * 0.8)
          color: Qt.rgba(Color.bar.text.r, Color.bar.text.g, Color.bar.text.b, 0.25)
        }
        // Sized from the plot, which is the tallest child: deriving this from
        // the parent Row would make the parent's implicit height depend on a
        // child that depends on it, and the strip collapses to zero.
        height: root.plotHeight

        Text {
          visible: root.config.showIcon
          text: root.iconFor(gauge.modelData)
          color: root.isUrgent(gauge.modelData) ? Color.urgent : Color.bar.text
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          renderType: Text.NativeRendering
        }

        Sparkline {
          width: root.config.sparklineWidth
          height: root.plotHeight
          primary: root.primarySeriesFor(gauge.modelData)
          secondary: root.secondarySeriesFor(gauge.modelData)
          ceiling: root.ceilingFor(gauge.modelData)
          stroke: root.colorFor(gauge.modelData)
          secondaryStroke: root.secondaryColorFor(gauge.modelData)
          mode: root.modeFor(gauge.modelData)
          floorValue: root.floorFor(gauge.modelData)
          urgentAt: root.urgentValueFor(gauge.modelData)
          // The threshold zone is the redundant, non-colour half of the
          // urgency signal, and it only means anything on a banded axis.
          showThreshold: gauge.modelData === "cputemp" || gauge.modelData === "gputemp"
          emphasizeLowLoad: root.config.emphasizeLowLoad
          revision: sampler.revision
        }

        Text {
          visible: root.config.showValue
          text: root.valueFor(gauge.modelData)
          color: root.isUrgent(gauge.modelData) ? Color.urgent : Color.bar.text
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          renderType: Text.NativeRendering
          horizontalAlignment: Text.AlignRight
          // Values churn between widths; reserving the widest keeps the
          // neighbouring bar widgets from shifting on every sample.
          width: valueMetrics.advanceWidth
          TextMetrics {
            id: valueMetrics
            font.family: button.fontFamily
            font.pixelSize: button.fontSize
            // Must match the Text below: NativeRendering rasterises through
            // the platform, and a measurement taken under a different render
            // type can disagree with what actually gets drawn.
            renderType: Text.NativeRendering
            // The widest string the format contract can produce for this
            // metric, measured in the theme's own font rather than assumed in
            // pixels. "888" because 8 is among the widest digits, and a
            // decimal point is narrower than a digit, so "8.8M" fits wherever
            // "888M" does. The reservation comes from the contract, never from
            // observed telemetry: sizing VRAM to what it "usually" reaches
            // would make the strip shuffle exactly when the machine is under
            // load and you are looking at it.
            text: root.labelTemplateFor(gauge.modelData)
          }
        }
      }
    }
  }

  Item {
    id: popupAnchor
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    // Wide enough that centring the card on this marker puts the card's right
    // edge on the widget's right edge. The panel positions with
    // x + width/2 - cardWidth/2, so a marker of the card's own width lines the
    // two right edges up.
    width: panelLoader.item ? panelLoader.item.cardWidth : 0
    height: parent.height
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The Row paints the strip on horizontal bars; this label is what a
    // vertical bar falls back to, since the Row does not lay out there.
    text: root.config.metrics.length > 0 ? root.valueFor(root.config.metrics[0]) : "\uF4BC"
    labelVisible: root.bar && root.bar.vertical
    active: root.opened
    useActiveColor: false
    horizontalMargin: 6
    fixedWidth: (root.bar && root.bar.vertical)
      ? -1
      : Math.max(12, (root.config.metrics.length === 0
                        ? placeholder.implicitWidth
                        : strip.implicitWidth) + scaledHorizontalMargin * 2)

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) readers.sampleAll()
      else root.togglePanel()
    }
  }

  IpcHandler {
    target: "takitani.sysmetrics"

    function refresh(): void { readers.sampleAll() }
    function toggleMetric(id: string): void { root.toggleMetric(id) }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }
}

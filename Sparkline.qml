import QtQuick
import qs.Commons
import "js/engine.js" as Engine

// Filled history plot. Draws one or two series against a shared ceiling.
//
// A Canvas repaints only when asked, so every input that changes the painted
// result needs an explicit requestPaint(): new data, a theme change, a resize,
// or becoming visible again. Binding alone is not enough — that is the single
// easiest way to end up with a blank or stale gauge.
Canvas {
  id: chart

  property var primary: []            // values, oldest first; NaN = gap
  property var secondary: []          // optional second series, stroke only
  property real ceiling: 100
  // Bottom of the plotted band. Non-zero for quantities that never approach
  // zero in practice: a CPU idling at 45 C against a 0 C baseline spends its
  // whole life in the top half of the box, and the variation that matters
  // flattens into a straight line.
  property real floorValue: 0
  // "area" fills under one series; "mirror" splits the box, primary above the
  // centre line and secondary below, which is the standard reading for a
  // two-directional quantity (rx/tx, read/write).
  property string mode: "area"
  // Value at which this metric becomes urgent, drawn as a shaded zone so the
  // warning is carried by position as well as by colour.
  property real urgentAt: NaN
  property bool showThreshold: false
  property color stroke: Color.accent
  // Second series colour. Defaults to the primary so rate gauges (rx/tx,
  // read/write) keep reading as one metric; the memory gauge overrides it to
  // tell swap apart from RAM.
  property color secondaryStroke: stroke
  property bool emphasizeLowLoad: true
  // Bump from outside on every sample to trigger a repaint.
  property int revision: 0

  renderStrategy: Canvas.Cooperative

  onRevisionChanged: requestPaint()
  onStrokeChanged: requestPaint()     // theme switch path
  onSecondaryStrokeChanged: requestPaint()
  onCeilingChanged: requestPaint()
  onFloorValueChanged: requestPaint()
  onModeChanged: requestPaint()
  onUrgentAtChanged: requestPaint()
  onShowThresholdChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  onVisibleChanged: if (visible) requestPaint()
  Component.onCompleted: requestPaint()

  function ratioFor(value) {
    var ratio = Engine.normalizeLevel(value, floorValue, ceiling)
    // The emphasis curve only makes sense on a zero-based axis; on a banded
    // one it would distort a reading that is already zoomed to its range.
    if (emphasizeLowLoad && floorValue === 0) ratio = Engine.emphasize(ratio)
    return ratio
  }

  function yFor(value, h) {
    // Half a pixel of headroom so a full-scale reading is not clipped by the
    // stroke width.
    return h - ratioFor(value) * (h - 1.5) - 0.75
  }

  // Mirrored mode: the primary grows up from the centre, the secondary down.
  function yMirrored(value, h, downward) {
    var mid = h / 2
    var extent = ratioFor(value) * (mid - 0.75)
    return downward ? mid + extent : mid - extent
  }

  // Walks a series as runs of consecutive real numbers, so a NaN gap breaks
  // the line instead of drawing a straight segment across missing time.
  function eachRun(values, callback) {
    if (!values || values.length < 2) return
    var run = []
    for (var i = 0; i < values.length; i++) {
      var v = values[i]
      if (isNaN(v)) {
        if (run.length > 1) callback(run)
        run = []
      } else {
        run.push({ index: i, value: v })
      }
    }
    if (run.length > 1) callback(run)
  }

  // ---- Painting ----------------------------------------------------------
  //
  // Four forms, because one form does not suit every quantity:
  //
  //   area    zero-based filled plot. Legitimate only where the baseline
  //           really is zero — filling shades an area to mean "amount", so a
  //           filled plot with a truncated axis overstates every value.
  //   line    unfilled stroke, used with a non-zero floor. This is how a
  //           banded quantity (temperature) is drawn: no fill, so no implied
  //           zero, so the band is honest.
  //   columns one bar per sample, for readings that sit at zero much of the
  //           time — a line interpolates between two zero-ish samples and
  //           invents activity that never happened.
  //   mirror  two directions around a centre line: primary above, secondary
  //           below. Collapsing rx and tx into one line destroys direction,
  //           which is half the information.

  function lastRealIndex() {
    var count = primary ? primary.length : 0
    var last = -1
    for (var i = count - 1; i >= 0; i--) {
      if (!isNaN(primary[i])) { last = i; break }
    }
    if (secondary) {
      for (var j = secondary.length - 1; j > last; j--) {
        if (!isNaN(secondary[j])) { last = j; break }
      }
    }
    return last
  }

  function paintTrough(ctx) {
    // Holds the gauge's shape before history has filled, so the strip does
    // not visibly grow during its first minute.
    ctx.fillStyle = Qt.rgba(stroke.r, stroke.g, stroke.b, 0.06)
    ctx.fillRect(0, 0, width, height)
  }

  // A shaded band marking the urgent zone. This is the non-colour cue that
  // keeps the warning legible: recolouring alone carries the meaning in hue
  // only, which fails for anyone who cannot separate the two colours.
  function paintThresholdZone(ctx) {
    if (isNaN(urgentAt) || urgentAt <= floorValue || urgentAt >= ceiling) return
    var y = yFor(urgentAt, height)
    ctx.fillStyle = Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
    ctx.fillRect(0, 0, width, y)
    ctx.strokeStyle = Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.45)
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(0, y + 0.5)
    ctx.lineTo(width, y + 0.5)
    ctx.stroke()
  }

  function strokeRun(ctx, run, stepX, colour, lineWidth, project) {
    ctx.beginPath()
    for (var i = 0; i < run.length; i++) {
      var x = run[i].index * stepX
      var y = project(run[i].value)
      if (i === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    }
    ctx.strokeStyle = colour
    ctx.lineWidth = lineWidth
    ctx.lineJoin = "round"
    ctx.stroke()
  }

  function paintArea(ctx, stepX) {
    var gradient = ctx.createLinearGradient(0, 0, 0, height)
    gradient.addColorStop(0, Qt.rgba(stroke.r, stroke.g, stroke.b, 0.55))
    gradient.addColorStop(1, Qt.rgba(stroke.r, stroke.g, stroke.b, 0.06))

    eachRun(primary, function(run) {
      ctx.beginPath()
      ctx.moveTo(run[0].index * stepX, height)
      for (var i = 0; i < run.length; i++)
        ctx.lineTo(run[i].index * stepX, chart.yFor(run[i].value, chart.height))
      ctx.lineTo(run[run.length - 1].index * stepX, height)
      ctx.closePath()
      ctx.fillStyle = gradient
      ctx.fill()
      chart.strokeRun(ctx, run, stepX, chart.stroke, 1.3,
                      function(v) { return chart.yFor(v, chart.height) })
    })

    if (secondary && secondary.length > 1) {
      eachRun(secondary, function(run) {
        chart.strokeRun(ctx, run, stepX,
                        Qt.rgba(chart.secondaryStroke.r, chart.secondaryStroke.g,
                                chart.secondaryStroke.b, 0.9), 1,
                        function(v) { return chart.yFor(v, chart.height) })
      })
    }
  }

  function paintLine(ctx, stepX) {
    eachRun(primary, function(run) {
      chart.strokeRun(ctx, run, stepX, chart.stroke, 1.3,
                      function(v) { return chart.yFor(v, chart.height) })
    })
    if (secondary && secondary.length > 1) {
      eachRun(secondary, function(run) {
        chart.strokeRun(ctx, run, stepX,
                        Qt.rgba(chart.secondaryStroke.r, chart.secondaryStroke.g,
                                chart.secondaryStroke.b, 0.9), 1,
                        function(v) { return chart.yFor(v, chart.height) })
      })
    }
  }

  readonly property real minColumnSlot: 3

  // How many of the most recent samples fit as legible columns.
  function columnWindow(lastReal) {
    var fits = Math.floor(width / minColumnSlot)
    return Math.max(1, Math.min(lastReal + 1, fits))
  }

  function paintColumns(ctx, stepX, lastReal) {
    var shown = columnWindow(lastReal)
    var first = lastReal + 1 - shown
    var slot = width / shown
    var barWidth = Math.max(1, slot - 1)
    ctx.fillStyle = stroke
    for (var i = first; i <= lastReal; i++) {
      var v = primary[i]
      if (isNaN(v)) continue
      var y = yFor(v, height)
      var h = height - y
      if (h < 1 && v > floorValue) h = 1     // keep a trace of a small reading
      if (h <= 0) continue
      ctx.fillRect((i - first) * slot, height - h, barWidth, h)
    }
  }

  function paintMirror(ctx, stepX, lastReal) {
    var shown = columnWindow(lastReal)
    var first = lastReal + 1 - shown
    var slot = width / shown
    var barWidth = Math.max(1, slot - 1)
    var mid = height / 2

    for (var i = first; i <= lastReal; i++) {
      var up = primary ? primary[i] : NaN
      if (!isNaN(up)) {
        var yUp = yMirrored(up, height, false)
        var hUp = mid - yUp
        if (hUp < 1 && up > floorValue) hUp = 1
        if (hUp > 0) {
          ctx.fillStyle = stroke
          ctx.fillRect((i - first) * slot, mid - hUp, barWidth, hUp)
        }
      }

      var down = secondary ? secondary[i] : NaN
      if (!isNaN(down)) {
        var yDown = yMirrored(down, height, true)
        var hDown = yDown - mid
        if (hDown < 1 && down > floorValue) hDown = 1
        if (hDown > 0) {
          ctx.fillStyle = Qt.rgba(secondaryStroke.r, secondaryStroke.g, secondaryStroke.b, 0.75)
          ctx.fillRect((i - first) * slot, mid, barWidth, hDown)
        }
      }
    }

    // Centre line: without it the two directions read as one jagged shape.
    ctx.strokeStyle = Qt.rgba(stroke.r, stroke.g, stroke.b, 0.35)
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(0, Math.round(mid) + 0.5)
    ctx.lineTo(width, Math.round(mid) + 0.5)
    ctx.stroke()
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.clearRect(0, 0, width, height)
    if (width <= 0 || height <= 0) return

    var lastReal = lastRealIndex()
    paintTrough(ctx)
    if (showThreshold) paintThresholdZone(ctx)
    if (lastReal < 1) return

    var stepX = width / lastReal
    if (mode === "mirror") paintMirror(ctx, stepX, lastReal)
    else if (mode === "columns") paintColumns(ctx, stepX, lastReal)
    else if (mode === "line") paintLine(ctx, stepX)
    else paintArea(ctx, stepX)
  }
}

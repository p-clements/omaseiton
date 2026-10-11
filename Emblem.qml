import QtQuick
import qs.Commons

// A small-size counterpart to the artwork: an open circle and three tidy lanes.
// Geometry is drawn at 24 units, then scaled to the shell's optical icon canvas.
Canvas {
  id: icon
  property color foreground: Color.bar.text
  property color accent: Color.accent
  onForegroundChanged: requestPaint()
  onAccentChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.scale(width / 24, height / 24)
    ctx.strokeStyle = foreground
    ctx.lineWidth = 2.2
    ctx.lineCap = "round"
    ctx.beginPath()
    ctx.arc(12, 12, 10, -0.45, 5.15)
    ctx.stroke()
    ctx.fillStyle = foreground
    var cells = [[6, 8], [6, 13], [10.5, 5.5], [10.5, 10.5], [10.5, 15.5], [15, 8], [15, 13]]
    for (var i = 0; i < cells.length; i++) {
      ctx.fillStyle = i === 3 ? accent : foreground
      ctx.fillRect(cells[i][0], cells[i][1], 3, 3)
    }
  }
}

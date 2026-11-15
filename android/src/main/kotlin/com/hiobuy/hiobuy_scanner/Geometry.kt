package com.hiobuy.hiobuy_scanner

/** Coordinate conversions between the Flutter view, the upright image and the sensor. All values are fractions (0–1). */
object Geometry {
    class Box(val left: Double, val top: Double, val right: Double, val bottom: Double) {
        val centerX get() = (left + right) / 2
        val centerY get() = (top + bottom) / 2
        fun contains(x: Double, y: Double) = x in left..right && y in top..bottom
        fun toList() = listOf(left, top, right, bottom)
    }

    val FULL = Box(0.0, 0.0, 1.0, 1.0)

    /**
     * Maps a point in a view to the upright image shown in it with
     * centre-crop ("cover") scaling. Unknown sizes map straight through.
     */
    fun viewToImage(x: Double, y: Double, viewW: Double, viewH: Double, imageW: Double, imageH: Double): Pair<Double, Double> {
        if (viewW <= 0 || viewH <= 0 || imageW <= 0 || imageH <= 0) return Pair(x, y)
        val scale = maxOf(viewW / imageW, viewH / imageH)
        val shownW = imageW * scale
        val shownH = imageH * scale
        val ix = (x * viewW + (shownW - viewW) / 2) / shownW
        val iy = (y * viewH + (shownH - viewH) / 2) / shownH
        return Pair(ix.coerceIn(0.0, 1.0), iy.coerceIn(0.0, 1.0))
    }

    fun viewToImage(box: Box, viewW: Double, viewH: Double, imageW: Double, imageH: Double): Box {
        val (l, t) = viewToImage(box.left, box.top, viewW, viewH, imageW, imageH)
        val (r, b) = viewToImage(box.right, box.bottom, viewW, viewH, imageW, imageH)
        return Box(l, t, r, b)
    }

    /**
     * Maps a point in the upright image to the un-rotated sensor buffer.
     * [rotationDegrees] is the clockwise rotation that makes the buffer upright.
     */
    fun uprightToSensor(u: Double, v: Double, rotationDegrees: Int): Pair<Double, Double> {
        return when (((rotationDegrees % 360) + 360) % 360) {
            90 -> Pair(v, 1 - u)
            180 -> Pair(1 - u, 1 - v)
            270 -> Pair(1 - v, u)
            else -> Pair(u, v)
        }
    }
}

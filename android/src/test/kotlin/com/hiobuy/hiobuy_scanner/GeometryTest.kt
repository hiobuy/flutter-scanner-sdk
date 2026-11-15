package com.hiobuy.hiobuy_scanner

import org.junit.Assert.assertEquals
import org.junit.Test

class GeometryTest {
    private val eps = 1e-9

    @Test
    fun sameAspectMapsStraightThrough() {
        val (x, y) = Geometry.viewToImage(0.25, 0.75, 360.0, 640.0, 720.0, 1280.0)
        assertEquals(0.25, x, eps)
        assertEquals(0.75, y, eps)
    }

    @Test
    fun tallerViewCropsImageSides() {
        // 9:16 image in a 9:20 view: scaled by height, sides cropped.
        val (cx, cy) = Geometry.viewToImage(0.5, 0.5, 360.0, 800.0, 720.0, 1280.0)
        assertEquals(0.5, cx, eps)
        assertEquals(0.5, cy, eps)
        val (lx, ty) = Geometry.viewToImage(0.0, 0.0, 360.0, 800.0, 720.0, 1280.0)
        assertEquals(0.1, lx, eps) // shown width 450, 45 px cropped each side
        assertEquals(0.0, ty, eps)
    }

    @Test
    fun unknownSizesMapStraightThrough() {
        val (x, y) = Geometry.viewToImage(0.3, 0.6, 0.0, 0.0, 720.0, 1280.0)
        assertEquals(0.3, x, eps)
        assertEquals(0.6, y, eps)
    }

    @Test
    fun uprightToSensorRotations() {
        // Top-left of an upright portrait image, sensor mounted at 90°.
        assertEquals(Pair(0.0, 1.0), Geometry.uprightToSensor(0.0, 0.0, 90))
        assertEquals(Pair(0.2, 0.3), Geometry.uprightToSensor(0.2, 0.3, 0))
        assertEquals(Pair(0.8, 0.7), Geometry.uprightToSensor(0.2, 0.3, 180))
        assertEquals(Pair(0.7, 0.2), Geometry.uprightToSensor(0.2, 0.3, 270))
    }
}

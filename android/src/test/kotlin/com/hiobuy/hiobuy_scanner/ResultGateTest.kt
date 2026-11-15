package com.hiobuy.hiobuy_scanner

import com.hiobuy.hiobuy_scanner.ResultGate.Decision
import com.hiobuy.hiobuy_scanner.ResultGate.Mode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ResultGateTest {
    private fun gate(mode: Mode = Mode.CONTINUOUS, windowMs: Double = 1500.0) =
        ResultGate().apply { configure(mode, windowMs) }

    @Test
    fun continuousReportsDifferentValuesBackToBack() {
        val g = gate()
        assertEquals(Decision.EMIT, g.offer("A", 0.0))
        assertEquals(Decision.EMIT, g.offer("B", 10.0))
        assertEquals(Decision.EMIT, g.offer("C", 20.0))
    }

    @Test
    fun valueHeldInViewIsReportedOnce() {
        val g = gate()
        assertEquals(Decision.EMIT, g.offer("A", 0.0))
        var t = 33.0
        while (t < 10_000) { // ten seconds of frames
            assertEquals(Decision.DUPLICATE, g.offer("A", t))
            t += 33.0
        }
    }

    @Test
    fun valueIsAcceptedAgainAfterLeavingViewForTheWindow() {
        val g = gate()
        assertEquals(Decision.EMIT, g.offer("A", 0.0))
        assertEquals(Decision.DUPLICATE, g.offer("A", 1000.0))
        assertEquals(Decision.DUPLICATE, g.offer("A", 2400.0)) // window restarts at last sighting
        assertEquals(Decision.EMIT, g.offer("A", 3900.0))
    }

    @Test
    fun resetDedupeAllowsImmediateRepeat() {
        val g = gate()
        assertEquals(Decision.EMIT, g.offer("A", 0.0))
        g.resetDedupe()
        assertEquals(Decision.EMIT, g.offer("A", 1.0))
    }

    @Test
    fun zeroWindowDisablesDedupe() {
        val g = gate(windowMs = 0.0)
        assertEquals(Decision.EMIT, g.offer("A", 0.0))
        assertEquals(Decision.EMIT, g.offer("A", 1.0))
    }

    @Test
    fun singleModeClosesAfterOneResultUntilOpened() {
        val g = gate(Mode.SINGLE)
        assertEquals(Decision.EMIT, g.offer("A", 0.0))
        assertFalse(g.isAccepting)
        assertEquals(Decision.CLOSED, g.offer("B", 10.0))
        g.open()
        assertTrue(g.isAccepting)
        assertEquals(Decision.EMIT, g.offer("B", 20.0))
    }

    @Test
    fun singleModeDoesNotRepeatParcelStillUnderCameraOnResume() {
        val g = gate(Mode.SINGLE)
        assertEquals(Decision.EMIT, g.offer("A", 0.0))
        var t = 33.0
        while (t < 5000) { // business layer takes 5 s; parcel never leaves view
            assertEquals(Decision.CLOSED, g.offer("A", t))
            t += 33.0
        }
        g.open()
        assertEquals(Decision.DUPLICATE, g.offer("A", t))
        assertEquals(Decision.EMIT, g.offer("B", t + 33))
    }

    @Test
    fun valueFirstSeenWhileClosedIsReportedOnOpen() {
        val g = gate()
        g.close()
        assertEquals(Decision.CLOSED, g.offer("A", 0.0))
        g.open()
        assertEquals(Decision.EMIT, g.offer("A", 10.0))
    }

    @Test
    fun memoryIsBoundedAndNeverBlocksForever() {
        val g = gate(windowMs = 60_000.0)
        for (i in 0 until 1000) assertEquals(Decision.EMIT, g.offer("code-$i", i.toDouble()))
        // The oldest entries were evicted, so they are accepted again.
        assertEquals(Decision.EMIT, g.offer("code-0", 1000.0))
        // Recent ones are still remembered.
        assertEquals(Decision.DUPLICATE, g.offer("code-999", 1001.0))
    }
}

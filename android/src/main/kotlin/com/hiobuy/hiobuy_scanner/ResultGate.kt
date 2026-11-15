package com.hiobuy.hiobuy_scanner

/**
 * Decides which detections become results: scan-mode gating plus time-window
 * de-duplication. Pure logic, safe to call from any thread.
 *
 * The iOS implementation (`ResultGate.swift`) must behave identically.
 */
class ResultGate {
    enum class Mode { SINGLE, CONTINUOUS }
    enum class Decision { EMIT, DUPLICATE, CLOSED }

    private var mode = Mode.CONTINUOUS
    private var windowMs = 1500.0
    private var accepting = true

    /** value → time it was last seen (not last emitted), in milliseconds. */
    private val lastSeen = HashMap<String, Double>()

    @Synchronized
    fun configure(mode: Mode, windowMs: Double) {
        this.mode = mode
        this.windowMs = maxOf(0.0, windowMs)
    }

    /**
     * Offers a detection made at [nowMs] (any monotonic clock).
     *
     * A value is a duplicate while it keeps being seen within the window, so a
     * barcode held in view is reported once, and reported again only after it
     * has been out of view for a full window (or after [resetDedupe]).
     */
    @Synchronized
    fun offer(value: String, nowMs: Double): Decision {
        val last = lastSeen[value]
        val seenRecently = windowMs > 0 && last != null && nowMs - last < windowMs
        if (windowMs > 0 && (seenRecently || accepting)) {
            // Refresh even while closed, so a parcel still under the camera when
            // the business layer resumes is not immediately reported a second time.
            remember(value, nowMs)
        }
        if (!accepting) return Decision.CLOSED
        if (seenRecently) return Decision.DUPLICATE
        if (mode == Mode.SINGLE) accepting = false
        return Decision.EMIT
    }

    /** Stops accepting results (pause, or after a single-mode result). */
    @Synchronized
    fun close() {
        accepting = false
    }

    @Synchronized
    fun open() {
        accepting = true
    }

    val isAccepting: Boolean
        @Synchronized get() = accepting

    @Synchronized
    fun resetDedupe() {
        lastSeen.clear()
    }

    private fun remember(value: String, nowMs: Double) {
        lastSeen[value] = nowMs
        if (lastSeen.size <= MAX_ENTRIES) return
        lastSeen.entries.removeAll { nowMs - it.value >= windowMs }
        while (lastSeen.size > MAX_ENTRIES) {
            val oldest = lastSeen.minByOrNull { it.value } ?: break
            lastSeen.remove(oldest.key)
        }
    }

    companion object {
        const val MAX_ENTRIES = 64
    }
}

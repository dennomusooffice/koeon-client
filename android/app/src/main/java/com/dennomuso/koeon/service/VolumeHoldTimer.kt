package com.dennomuso.koeon.service

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** At most two pending volume holds; callers revalidate ownership at delivery. */
class VolumeHoldTimer(private val scope: CoroutineScope, private val now: () -> Long) {
    private val jobs = mutableMapOf<Int, Job>()
    fun start(key: Int, downAt: Long, fire: () -> Unit) {
        if (key != 24 && key != 25) return
        release(key)
        jobs[key] = scope.launch {
            delay((BackgroundVolumeKeyGate.LONG_PRESS_MS - (now() - downAt)).coerceAtLeast(1))
            jobs.remove(key)
            fire()
        }
    }
    fun release(key: Int) { jobs.remove(key)?.cancel() }
    fun clear() { jobs.values.forEach { it.cancel() }; jobs.clear() }
}

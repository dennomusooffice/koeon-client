package com.dennomuso.koeon.core.session

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

internal data class OutputVolume(val index: Int, val maximum: Int)

/** Main-thread owned, read-only UI observation. Never keeps a background audio session alive. */
internal class OutputVolumeObserver(
    private val scope: CoroutineScope,
    private val readIndex: () -> Int,
    private val readMaximum: () -> Int,
    private val publish: (OutputVolume?) -> Unit,
) {
    private var job: Job? = null

    fun setActive(active: Boolean) {
        if (!active) {
            job?.cancel()
            job = null
            return
        }
        if (job?.isActive == true) return
        refresh()
        job = scope.launch {
            while (isActive) {
                delay(500)
                refresh()
            }
        }
    }

    fun refresh() {
        var snapshot: OutputVolume? = null
        // Route changes may alter the range between Binder calls. Retry only once.
        for (attempt in 0 until 2) {
            try {
                val before = readMaximum()
                val index = readIndex()
                val after = readMaximum()
                if (before == after && after > 0 && index in 0..after) {
                    snapshot = OutputVolume(index, after)
                    break
                }
            } catch (_: RuntimeException) {
                break
            }
        }
        publish(snapshot)
    }
}

package com.dennomuso.koeon.core.session

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class OutputVolumeObserverTest {
    @Test fun foregroundTracksExternalIndexAndRangeChangesWithoutDuplicateJobs() = runTest {
        var index = 8
        var maximum = 11
        val values = mutableListOf<OutputVolume?>()
        val observer = OutputVolumeObserver(backgroundScope, { index }, { maximum }, values::add)
        observer.setActive(true)
        observer.setActive(true)
        runCurrent()
        assertEquals(listOf(OutputVolume(8, 11)), values)
        index = 7
        maximum = 15
        advanceTimeBy(500)
        runCurrent()
        assertEquals(listOf(OutputVolume(8, 11), OutputVolume(7, 15)), values)
        observer.setActive(false)
        index = 6
        advanceTimeBy(2000)
        runCurrent()
        assertEquals(2, values.size)
        observer.setActive(true)
        assertEquals(OutputVolume(6, 15), values.last())
        observer.setActive(false)
    }

    @Test fun rangeChangingDuringReadIsRetriedOnce() = runTest {
        val maxima = ArrayDeque(listOf(11, 15, 15, 15))
        var result: OutputVolume? = null
        OutputVolumeObserver(backgroundScope, { 12 }, { maxima.removeFirst() }, { result = it }).refresh()
        assertEquals(OutputVolume(12, 15), result)
        assertTrue(maxima.isEmpty())
    }

    @Test fun invalidOrUnavailableApiClearsPreviouslyPublishedValue() = runTest {
        var index = 8
        var maximum = 15
        var fail = false
        val values = mutableListOf<OutputVolume?>()
        val observer = OutputVolumeObserver(backgroundScope,
            { if (fail) throw SecurityException() else index }, { maximum }, values::add)
        observer.refresh()
        index = 16
        observer.refresh()
        maximum = 0
        observer.refresh()
        maximum = 15
        index = 8
        fail = true
        observer.refresh()
        assertEquals(listOf(OutputVolume(8, 15), null, null, null), values)
    }

    @Test fun continuouslyChangingRangeHasBoundedReads() = runTest {
        var calls = 0
        var result: OutputVolume? = OutputVolume(1, 2)
        OutputVolumeObserver(backgroundScope, { 1 }, { ++calls }, { result = it }).refresh()
        assertEquals(4, calls)
        assertNull(result)
    }
}

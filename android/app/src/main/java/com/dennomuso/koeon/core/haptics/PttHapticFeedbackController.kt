package com.dennomuso.koeon.core.haptics

enum class HapticType {
    PRESS,
    RELEASE,
}

enum class HapticResult(val diagnosticValue: String) {
    PLAYED("played"),
    UNSUPPORTED("unsupported"),
    DISABLED("disabled"),
    FAILED("failed"),
    SKIPPED_DUPLICATE("skipped_duplicate"),
    NOT_PLAYED("not_played"),
}

data class HapticSnapshot(
    val supported: Boolean = false,
    val enabled: Boolean = false,
    val inputPressed: Boolean = false,
    val lastType: HapticType? = null,
    val lastAtEpochMs: Long? = null,
    val lastResult: HapticResult = HapticResult.NOT_PLAYED,
)

interface HapticPerformer {
    val supported: Boolean
    val enabled: Boolean
    fun prepare()
    fun performPress(): Boolean
    fun performRelease(): Boolean
}

/** Input feedback is deliberately independent of Floor, Cue, and microphone state. */
class PttHapticFeedbackController(
    private val performer: HapticPerformer,
    private val nowEpochMs: () -> Long = System::currentTimeMillis,
    private val onSnapshot: (HapticSnapshot) -> Unit = {},
) {
    private var inputPressed = false
    private var snapshot = HapticSnapshot(
        supported = performer.supported,
        enabled = performer.enabled,
    )

    fun current(): HapticSnapshot = snapshot

    fun prepare() {
        runCatching { performer.prepare() }
        emit(snapshot.copy(supported = performer.supported, enabled = performer.enabled))
    }

    fun press(eligible: Boolean): Boolean {
        if (!eligible) return false
        if (inputPressed) {
            record(HapticType.PRESS, HapticResult.SKIPPED_DUPLICATE)
            return false
        }
        inputPressed = true
        play(HapticType.PRESS) { performer.performPress() }
        return true
    }

    fun release(): Boolean {
        if (!inputPressed) {
            record(HapticType.RELEASE, HapticResult.SKIPPED_DUPLICATE)
            return false
        }
        inputPressed = false
        play(HapticType.RELEASE) { performer.performRelease() }
        return true
    }

    fun cancel() {
        if (!inputPressed) return
        inputPressed = false
        emit(snapshot.copy(inputPressed = false))
    }

    private fun play(type: HapticType, action: () -> Boolean) {
        val result = when {
            !performer.supported -> HapticResult.UNSUPPORTED
            !performer.enabled -> HapticResult.DISABLED
            else -> runCatching { action() }
                .fold(
                    onSuccess = { if (it) HapticResult.PLAYED else HapticResult.FAILED },
                    onFailure = { HapticResult.FAILED },
                )
        }
        record(type, result)
    }

    private fun record(type: HapticType, result: HapticResult) {
        emit(
            snapshot.copy(
                supported = performer.supported,
                enabled = performer.enabled,
                inputPressed = inputPressed,
                lastType = type,
                lastAtEpochMs = nowEpochMs(),
                lastResult = result,
            ),
        )
    }

    private fun emit(value: HapticSnapshot) {
        snapshot = value
        onSnapshot(value)
    }
}

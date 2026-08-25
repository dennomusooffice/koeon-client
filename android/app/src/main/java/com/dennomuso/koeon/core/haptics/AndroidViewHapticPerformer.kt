package com.dennomuso.koeon.core.haptics

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View

/** Uses OS semantic feedback and therefore respects the device's system haptic setting. */
class AndroidViewHapticPerformer(
    private val view: View,
) : HapticPerformer {
    override val supported: Boolean = true
    override val enabled: Boolean get() = view.isHapticFeedbackEnabled

    override fun prepare() = Unit

    override fun performPress(): Boolean =
        view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)

    override fun performRelease(): Boolean {
        val feedback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            HapticFeedbackConstants.VIRTUAL_KEY_RELEASE
        } else {
            HapticFeedbackConstants.VIRTUAL_KEY
        }
        return view.performHapticFeedback(feedback)
    }
}

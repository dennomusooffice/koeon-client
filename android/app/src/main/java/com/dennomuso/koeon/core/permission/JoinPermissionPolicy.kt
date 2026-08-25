package com.dennomuso.koeon.core.permission

import com.dennomuso.koeon.core.model.Role

object JoinPermissionPolicy {
    fun microphoneRequired(role: Role?): Boolean = role != Role.LISTENER

    fun canJoin(role: Role?, microphoneGranted: Boolean): Boolean =
        !microphoneRequired(role) || microphoneGranted
}

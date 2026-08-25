package com.dennomuso.koeon.core.permission

import com.dennomuso.koeon.core.model.Role
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class JoinPermissionPolicyTest {
    @Test fun `staff cannot join PTT when microphone is denied`() {
        assertFalse(JoinPermissionPolicy.canJoin(Role.STAFF, microphoneGranted = false))
    }

    @Test fun `listener can join without microphone permission`() {
        assertTrue(JoinPermissionPolicy.canJoin(Role.LISTENER, microphoneGranted = false))
    }
}

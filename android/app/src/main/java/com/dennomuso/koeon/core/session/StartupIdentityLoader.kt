package com.dennomuso.koeon.core.session

import com.dennomuso.koeon.core.api.KoeonApiException
import com.dennomuso.koeon.core.auth.DeviceCredentialStore
import kotlinx.coroutines.CancellationException

internal sealed interface StartupIdentityResult<out T> {
    data class Loaded<T>(val identity: T) : StartupIdentityResult<T>
    data object EnrollmentRequired : StartupIdentityResult<Nothing>
    data object Superseded : StartupIdentityResult<Nothing>
    data object Retry : StartupIdentityResult<Nothing>
}

/** A failed read or request is not evidence that the saved enrollment is absent. */
internal suspend fun <T> loadStartupIdentity(
    store: DeviceCredentialStore,
    fetch: suspend () -> T,
): StartupIdentityResult<T> {
    try {
        val credential = store.read() ?: return StartupIdentityResult.EnrollmentRequired
        val identity = try {
            fetch()
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            if (store.read() != credential) return StartupIdentityResult.Superseded
            if (error is KoeonApiException && error.statusCode == 401 &&
                error.errorCode in setOf("DEVICE_CREDENTIAL_INVALID", "DEVICE_CREDENTIAL_EXPIRED")) {
                store.clear()
                return StartupIdentityResult.EnrollmentRequired
            }
            return StartupIdentityResult.Retry
        }
        return if (store.read() == credential) StartupIdentityResult.Loaded(identity)
        else StartupIdentityResult.Superseded
    } catch (error: Exception) {
        if (error is CancellationException) throw error
        return StartupIdentityResult.Retry
    }
}

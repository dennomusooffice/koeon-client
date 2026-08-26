package com.dennomuso.koeon.core.api

import java.net.URI

object KoeonApiBaseUrlConfiguration {
    const val PUBLIC_SAFE_BASE_URL = "https://example.invalid"

    fun resolve(configuredValue: String?): String {
        val value = configuredValue?.trim().orEmpty()
        if (value.isEmpty()) return PUBLIC_SAFE_BASE_URL

        val uri = runCatching { URI(value) }.getOrNull() ?: return PUBLIC_SAFE_BASE_URL
        val valid = uri.scheme.equals("https", ignoreCase = true) &&
            !uri.host.isNullOrBlank() &&
            uri.rawUserInfo == null &&
            uri.rawQuery == null &&
            uri.rawFragment == null
        return if (valid) value.trimEnd('/') else PUBLIC_SAFE_BASE_URL
    }
}

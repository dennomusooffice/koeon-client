package com.dennomuso.koeon.core.enrollment

import java.net.URI

private const val INVITE_ORIGIN = "https://example.invalid"
private const val INVITE_PATH = "/join"
private val TOKEN_PATTERN = Regex("^[A-Za-z0-9_-]{43}$")
private val CODE_PATTERN = Regex("^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{10}$")

sealed interface EnrollmentCredential {
    data class Token(val value: String) : EnrollmentCredential
    data class Code(val value: String) : EnrollmentCredential
}

object InviteInputParser {
    fun parse(value: String): String {
        val input = value.trim()
        if (TOKEN_PATTERN.matches(input)) return input
        val uri = runCatching { URI(input) }.getOrNull()
            ?: throw IllegalArgumentException("Invite must be a KOEON URL or token")
        val origin = "${uri.scheme}://${uri.host}${if (uri.port == -1) "" else ":${uri.port}"}"
        val token = uri.rawFragment.orEmpty()
        if (
            origin != INVITE_ORIGIN ||
            uri.rawPath != INVITE_PATH ||
            uri.rawQuery != null ||
            uri.rawUserInfo != null ||
            !TOKEN_PATTERN.matches(token)
        ) {
            throw IllegalArgumentException("Invite URL origin, path, or fragment is invalid")
        }
        return token
    }
}

object EnrollmentInputParser {
    fun parse(value: String): EnrollmentCredential {
        val normalizedCode = value.trim().uppercase().replace(Regex("[\\s-]"), "")
        if (CODE_PATTERN.matches(normalizedCode)) return EnrollmentCredential.Code(normalizedCode)
        return EnrollmentCredential.Token(InviteInputParser.parse(value))
    }
}

/** Stateless routing keeps the raw Invite token in call-stack memory only. */
class InviteDeepLinkRouter(private val deliver: (String) -> Unit) {
    fun route(url: String?): Boolean {
        if (url == null) return false
        val token = runCatching { InviteInputParser.parse(url) }.getOrNull() ?: return false
        deliver(token)
        return true
    }
}

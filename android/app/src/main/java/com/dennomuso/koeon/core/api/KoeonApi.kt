package com.dennomuso.koeon.core.api

import com.dennomuso.koeon.core.model.ApiErrorEnvelope
import com.dennomuso.koeon.core.model.FixtureResponse
import com.dennomuso.koeon.core.model.FloorResponse
import com.dennomuso.koeon.core.model.JoinRequest
import com.dennomuso.koeon.core.ptt.PTT_RX_READY_VERSION
import com.dennomuso.koeon.core.model.JoinResponse
import com.dennomuso.koeon.core.model.EnrollmentRequest
import com.dennomuso.koeon.core.model.EnrollmentResponse
import com.dennomuso.koeon.core.model.MeResponse
import com.dennomuso.koeon.core.model.LeaseRequest
import com.dennomuso.koeon.core.model.LeaveResponse
import com.dennomuso.koeon.core.model.SessionRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

interface KoeonApi {
    suspend fun fixture(): FixtureResponse
    suspend fun enroll(request: EnrollmentRequest): EnrollmentResponse
    suspend fun me(): MeResponse
    suspend fun join(userId: String, channelId: String, wantsToPublish: Boolean): JoinResponse
    suspend fun leave(sessionId: String): LeaveResponse
    suspend fun acquire(sessionId: String): FloorResponse
    suspend fun renew(sessionId: String, leaseId: String): FloorResponse
    suspend fun release(sessionId: String, leaseId: String): FloorResponse
    suspend fun floorStatus(sessionId: String): FloorResponse
    suspend fun logout()
}

class KoeonApiException(
    val statusCode: Int,
    val errorCode: String?,
    message: String,
) : IOException(message)

class HttpKoeonApi(
    baseUrl: String,
    private val credentialProvider: () -> String? = { null },
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .build(),
    private val json: Json = Json { ignoreUnknownKeys = true; explicitNulls = false },
) : KoeonApi {
    private val root = baseUrl.trimEnd('/')
    private val mediaType = "application/json; charset=utf-8".toMediaType()

    override suspend fun fixture(): FixtureResponse = get("/api/fixture")

    override suspend fun enroll(request: EnrollmentRequest): EnrollmentResponse =
        post("/api/auth/enroll", request, authenticated = false)

    override suspend fun me(): MeResponse = get("/api/me")

    override suspend fun join(
        userId: String,
        channelId: String,
        wantsToPublish: Boolean,
    ): JoinResponse = post(
        "/api/join",
        JoinRequest(channelId, wantsToPublish, if (wantsToPublish) PTT_RX_READY_VERSION else null),
    )

    override suspend fun leave(sessionId: String): LeaveResponse =
        post("/api/leave", SessionRequest(sessionId))

    override suspend fun acquire(sessionId: String): FloorResponse =
        post("/api/floor/acquire", SessionRequest(sessionId))

    override suspend fun renew(sessionId: String, leaseId: String): FloorResponse =
        post("/api/floor/renew", LeaseRequest(sessionId, leaseId))

    override suspend fun release(sessionId: String, leaseId: String): FloorResponse =
        post("/api/floor/release", LeaseRequest(sessionId, leaseId))

    override suspend fun floorStatus(sessionId: String): FloorResponse =
        get("/api/floor/status?sessionId=${java.net.URLEncoder.encode(sessionId, Charsets.UTF_8.name())}")

    override suspend fun logout() {
        post<EmptyRequest, LogoutResponse>("/api/auth/logout", EmptyRequest())
    }

    private suspend inline fun <reified T> get(path: String): T = execute(
        authenticatedBuilder(path).get().header("Cache-Control", "no-store").build(),
    )

    private suspend inline fun <reified RequestType, reified ResponseType> post(
        path: String,
        body: RequestType,
        authenticated: Boolean = true,
    ): ResponseType = execute(
        (if (authenticated) authenticatedBuilder(path) else Request.Builder().url(root + path))
            .post(json.encodeToString(body).toRequestBody(mediaType))
            .build(),
    )

    private fun authenticatedBuilder(path: String): Request.Builder {
        val builder = Request.Builder().url(root + path)
        credentialProvider()?.takeIf { it.isNotBlank() }?.let { builder.header("Authorization", "Bearer $it") }
        return builder
    }

    private suspend inline fun <reified T> execute(request: Request): T = withContext(Dispatchers.IO) {
        client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                val envelope = runCatching { json.decodeFromString<ApiErrorEnvelope>(body) }.getOrNull()
                throw KoeonApiException(
                    response.code,
                    envelope?.error?.code,
                    envelope?.error?.message ?: "KOEON request failed (${response.code})",
                )
            }
            if (body.isBlank()) throw IOException("KOEON response was empty")
            json.decodeFromString<T>(body)
        }
    }
}

@kotlinx.serialization.Serializable
private class EmptyRequest

@kotlinx.serialization.Serializable
private data class LogoutResponse(val outcome: String)

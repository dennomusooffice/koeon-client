package com.dennomuso.koeon.core.model

import kotlinx.serialization.Serializable

@Serializable
enum class Role { ADMIN, STAFF, LISTENER }

@Serializable
data class Tenant(val id: String, val name: String)

@Serializable
data class Workspace(val id: String, val tenantId: String, val name: String)

@Serializable
data class Channel(val id: String, val workspaceId: String, val name: String)

@Serializable
data class User(
    val id: String,
    val workspaceId: String,
    val name: String,
    val role: Role,
    // Fixture responses include memberships, while Join responses return the
    // domain User without channelIds. Keep one shared model without making the
    // stricter Fixture-only field a Join decoding requirement.
    val channelIds: List<String> = emptyList(),
)

@Serializable
data class FixtureResponse(
    val tenant: Tenant,
    val workspace: Workspace,
    val channels: List<Channel>,
    val users: List<User>,
)

@Serializable
data class JoinRequest(
    val channelId: String,
    val wantsToPublish: Boolean,
    val rxReadyProtocolVersion: Int? = null,
)

@Serializable
data class IdentityUser(val id: String, val displayName: String, val role: Role)

@Serializable
data class IdentityWorkspace(val id: String, val name: String)

@Serializable
data class IdentityDevice(val id: String, val name: String? = null, val platform: String)

@Serializable
data class IdentityChannel(val id: String, val name: String, val type: String)

@Serializable
data class MeResponse(
    val user: IdentityUser,
    val workspace: IdentityWorkspace,
    val device: IdentityDevice,
    val channels: List<IdentityChannel>,
)

@Serializable
data class EnrollmentRequest(
    val token: String? = null,
    val code: String? = null,
    val platform: String,
    val deviceName: String,
    val osVersion: String,
    val appVersion: String,
)

@Serializable
data class EnrollmentResponse(
    val identity: MeResponse,
    val credentialExpiresAt: String,
    val deviceCredential: String,
)

@Serializable
data class JoinChannel(val id: String, val name: String)

@Serializable
data class JoinResponse(
    val sessionId: String,
    val livekitUrl: String,
    val token: String,
    val roomName: String,
    val user: User,
    val channel: JoinChannel,
    val canPublish: Boolean,
    val tokenExpiresInSeconds: Int,
    val tokenExpiresAt: String? = null,
    val deviceId: String? = null,
)

@Serializable
data class SessionRequest(val sessionId: String)

@Serializable
data class LeaseRequest(val sessionId: String, val leaseId: String)

@Serializable
data class FloorOwner(val id: String, val name: String)

@Serializable
data class FloorResponse(
    val outcome: String,
    val owner: FloorOwner? = null,
    val leaseId: String? = null,
    val acquiredAt: String? = null,
    val leaseExpiresAt: String? = null,
    val maxTxExpiresAt: String? = null,
    val lastRenewedAt: String? = null,
    val isOwner: Boolean = false,
    val rxReadyExpectedSessionIds: List<String> = emptyList(),
    val rxReadyExpectedDeviceIds: List<String> = emptyList(),
    val wakeRecipientCount: Int = 0,
)

@Serializable
data class LeaveResponse(val outcome: String)

@Serializable
data class ApiErrorEnvelope(val error: ApiError? = null)

@Serializable
data class ApiError(val code: String? = null, val message: String? = null)

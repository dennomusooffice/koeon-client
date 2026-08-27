package com.dennomuso.koeon.core.livekit

import android.content.Context
import android.media.AudioManager
import io.livekit.android.AudioOptions
import com.dennomuso.koeon.core.ptt.MicrophoneGateway
import com.dennomuso.koeon.core.audio.TonePttCuePlayer
import com.dennomuso.koeon.core.audio.CueRole
import com.dennomuso.koeon.core.audio.InputGainProcessor
import com.dennomuso.koeon.core.audio.AudioBitratePreset
import com.dennomuso.koeon.core.ptt.PTT_CONTROL_TOPIC
import com.dennomuso.koeon.core.ptt.PTT_CONTROL_FAST_START_TOPIC
import com.dennomuso.koeon.core.ptt.PttControlEvent
import com.dennomuso.koeon.core.ptt.PttControlGateway
import com.dennomuso.koeon.core.ptt.PTT_RX_READY_TOPIC
import com.dennomuso.koeon.core.ptt.PTT_RX_READY_VERSION
import com.dennomuso.koeon.core.ptt.PttRxReadyEvent
import com.dennomuso.koeon.core.ptt.RxReadyBarrier
import com.dennomuso.koeon.core.ptt.RxReadyAcceptance
import com.dennomuso.koeon.core.ptt.RxReadyReason
import com.dennomuso.koeon.core.ptt.RxReadyReconcileSource
import com.dennomuso.koeon.core.ptt.RxReadyResult
import com.dennomuso.koeon.core.ptt.RxAudioController
import com.dennomuso.koeon.core.ptt.RxSnapshot
import com.dennomuso.koeon.core.ptt.pttControlJson
import com.dennomuso.koeon.core.ptt.pttRxReadyJson
import com.dennomuso.koeon.core.model.FloorResponse
import io.livekit.android.LiveKit
import io.livekit.android.LiveKitOverrides
import io.livekit.android.audio.AudioSwitchHandler
import io.livekit.android.events.RoomEvent
import io.livekit.android.events.collect
import io.livekit.android.room.Room
import io.livekit.android.room.track.RemoteAudioTrack
import io.livekit.android.room.track.LocalAudioTrackOptions
import io.livekit.android.room.track.DataPublishReliability
import io.livekit.android.room.participant.AudioTrackPublishDefaults
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.time.Instant

enum class IntercomConnectionState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    RECONNECTING,
}

sealed interface AudioFocusEvent {
    data object Gained : AudioFocusEvent
    data class Lost(val reason: String) : AudioFocusEvent
}

internal fun mapLiveKitState(state: Room.State): IntercomConnectionState = when (state) {
    Room.State.DISCONNECTED -> IntercomConnectionState.DISCONNECTED
    Room.State.CONNECTING -> IntercomConnectionState.CONNECTING
    Room.State.CONNECTED -> IntercomConnectionState.CONNECTED
    Room.State.RECONNECTING -> IntercomConnectionState.RECONNECTING
}

data class LiveKitSnapshot(
    val connectionState: IntercomConnectionState = IntercomConnectionState.DISCONNECTED,
    val roomName: String? = null,
    val participantNames: List<String> = emptyList(),
    val activeSpeaker: String? = null,
    val reconnectCount: Int = 0,
    val connectionQuality: String = "Unavailable",
    val audioFocusState: String = "Inactive",
    val audioRoute: String = "Unavailable",
    val remoteAudioTracks: Int = 0,
    val microphoneTrackState: String = "not_published",
    val remoteAudioState: String = "no_tracks",
    val rxReadyExpectedCount: Int = 0,
    val rxReadyReceivedCount: Int = 0,
    val rxReadyLateCount: Int = 0,
    val rxReadyProtocolVersion: Int = PTT_RX_READY_VERSION,
    val rxReadyPublishAttemptedAt: Instant? = null,
    val rxReadyPublishedAt: Instant? = null,
    val rxReadyPublishResult: String = "NOT_ATTEMPTED",
    val rxReadyPublishFailureClass: String? = null,
    val rxReadyStartReceivedAt: Instant? = null,
    val rxReadyStartArmedAt: Instant? = null,
    val rxReadySenderIdentityPresent: Boolean? = null,
    val rxReadyReceiverDeviceIdPresent: Boolean? = null,
    val rxReadyReceivedEvents: Int = 0,
    val rxReadyRejectedCount: Int = 0,
    val rxReadyRejectedSessionMismatch: Int = 0,
    val rxReadyRejectedDeviceMismatch: Int = 0,
    val rxReadyRejectedParticipantMetadataMissing: Int = 0,
    val rxReadyRejectedLeaseMismatch: Int = 0,
    val rxReadyRejectedChannelMismatch: Int = 0,
    val rxReadyRejectedDuplicate: Int = 0,
    val rxReadyRejectedDeadlineExpired: Int = 0,
    val rxReadyPendingMetadataCount: Int = 0,
    val rxReadyPendingMetadataEvents: Int = 0,
    val rxReadyPendingOldestAgeMs: Long? = null,
    val rxReadyPendingMaximumObservedAgeMs: Long = 0,
    val rxReadyBarrierStartedAtElapsedRealtimeMs: Long? = null,
    val rxReadyBarrierDeadlineAtElapsedRealtimeMs: Long? = null,
    val rxReadyMetadataAvailableAt: Instant? = null,
    val rxReadyLastReconcileSource: String? = null,
    val rxReadyTimeoutReason: String? = null,
    val rxReadyFirstEventReceivedAt: Instant? = null,
    val rxReadyFirstAcceptedAt: Instant? = null,
    val rx: RxSnapshot = RxSnapshot(),
    val lastError: String? = null,
    val deployment: String = "UNKNOWN",
    val endpointHost: String? = null,
    val effectiveAudioBitrateKbps: Int? = null,
)

internal data class AudioCaptureProcessingPolicy(
    val echoCancellation: Boolean = true,
    val noiseSuppression: Boolean = true,
    val autoGainControl: Boolean = true,
    val highPassFilter: Boolean = true,
    val typingNoiseDetection: Boolean = true,
) {
    fun toTrackOptions() = LocalAudioTrackOptions(
        noiseSuppression = noiseSuppression,
        echoCancellation = echoCancellation,
        autoGainControl = autoGainControl,
        highPassFilter = highPassFilter,
        typingNoiseDetection = typingNoiseDetection,
    )
}

enum class AudioCaptureProfile(
    val webRtcAgcEnabled: Boolean,
    val koeonGainMode: com.dennomuso.koeon.core.audio.InputGainMode,
) {
    A_CURRENT(true, com.dennomuso.koeon.core.audio.InputGainMode.AUTO),
    B_GAIN_OFF(false, com.dennomuso.koeon.core.audio.InputGainMode.OFF),
    C_KOEON_OWNER(false, com.dennomuso.koeon.core.audio.InputGainMode.AUTO),
    D_WEBRTC_OWNER(true, com.dennomuso.koeon.core.audio.InputGainMode.OFF),
    ;

    internal val capturePolicy = AudioCaptureProcessingPolicy(autoGainControl = webRtcAgcEnabled)
}

internal val productionAudioCaptureProfile = AudioCaptureProfile.D_WEBRTC_OWNER

internal fun audioTrackPublishDefaults(preset: AudioBitratePreset) =
    AudioTrackPublishDefaults(audioBitrate = preset.bitsPerSecond)

internal data class LiveKitEndpointDiagnostic(val deployment: String, val host: String?)

internal fun liveKitEndpointDiagnostic(url: String): LiveKitEndpointDiagnostic {
    val host = runCatching { java.net.URI(url).host?.lowercase()?.takeIf(String::isNotBlank) }.getOrNull()
    val deployment = when (host) {
        "livekit.example.invalid" -> "SELF_HOST"
        null -> "UNKNOWN"
        else -> if (host.endsWith(".livekit.cloud")) "CLOUD" else "UNKNOWN"
    }
    return LiveKitEndpointDiagnostic(deployment, host)
}

internal fun rxReadyCapableDeviceId(metadata: String?): String? = runCatching {
    val objectValue = metadata?.let { pttRxReadyJson.parseToJsonElement(it).jsonObject } ?: return@runCatching null
    val version = objectValue["rxReadyProtocolVersion"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()
    objectValue["deviceId"]?.jsonPrimitive?.contentOrNull?.takeIf {
        version == PTT_RX_READY_VERSION && it.isNotBlank()
    }
}.getOrNull()

internal fun rxReadyPublishFailureClass(error: Throwable): String =
    error.javaClass.simpleName.take(80).ifBlank { "Throwable" }

/**
 * Owns one LiveKit Room for the whole intercom session. PTT only mutes/unmutes
 * the microphone publication and never reconnects this Room.
 */
class LiveKitRoomController(
    context: Context,
    private val scope: CoroutineScope,
    private val inputGainProcessor: InputGainProcessor? = null,
    private val onAudioFocusEvent: (AudioFocusEvent) -> Unit = {},
) : MicrophoneGateway, PttControlGateway {
    private var audioCaptureProfile = productionAudioCaptureProfile
    private val appContext = context.applicationContext
    private val audioHandler = AudioSwitchHandler(appContext).also { handler ->
        // Some Android vendors do not apply the communication route unless the
        // SDK is explicitly allowed to manage it. KOEON is always a voice-chat
        // session, so keep the SDK on its documented communication mode.
        handler.audioMode = AudioManager.MODE_IN_COMMUNICATION
        handler.forceHandleAudioRouting = true
        handler.registerAudioDeviceChangeListener { _, selected ->
            _snapshot.value = _snapshot.value.copy(
                audioRoute = selected?.toString() ?: "Unavailable",
            )
        }
        handler.registerOnAudioFocusChangeListener { change ->
            when (change) {
                AudioManager.AUDIOFOCUS_GAIN -> {
                    _snapshot.value = _snapshot.value.copy(audioFocusState = "Granted")
                    onAudioFocusEvent(AudioFocusEvent.Gained)
                }
                AudioManager.AUDIOFOCUS_LOSS,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
                -> {
                    _snapshot.value = _snapshot.value.copy(audioFocusState = "Lost")
                    onAudioFocusEvent(AudioFocusEvent.Lost("Android audio focus change $change"))
                }
            }
        }
    }
    private var room: Room? = null
    private var eventJob: Job? = null
    private var prewarmedTrack: io.livekit.android.room.track.LocalAudioTrack? = null
    private var microphoneEnabled = false
    private var channelId: String? = null
    private var userId: String? = null
    private var sessionId: String? = null
    private var deviceId: String? = null
    private var controlSequence = 0L
    private var rxAudio: RxAudioController? = null
    private var rxReadyBarrier: RxReadyBarrier? = null
    private var rxReadyReconcileJob: Job? = null
    private var rxReadyLeaseId: String? = null
    private var rxReadyPublishLeaseId: String? = null
    private var rxReadyStartLeaseId: String? = null
    var onBufferedAudioStart: (String) -> Unit = {}

    private val _snapshot = MutableStateFlow(LiveKitSnapshot())
    val snapshot: StateFlow<LiveKitSnapshot> = _snapshot.asStateFlow()

    suspend fun connect(
        url: String,
        token: String,
        roomName: String,
        canPublish: Boolean,
        channelId: String,
        userId: String,
        sessionId: String,
        deviceId: String?,
        audioBitratePreset: AudioBitratePreset,
    ) {
        disconnect()
        this.channelId = channelId
        this.userId = userId
        this.sessionId = sessionId
        this.deviceId = deviceId
        controlSequence = 0
        rxAudio = RxAudioController(
            scope = scope,
            channelId = channelId,
            cuePlayer = TonePttCuePlayer(appContext, CueRole.RX),
            onSnapshot = { rx -> _snapshot.value = _snapshot.value.copy(rx = rx) },
        )
        val nextRoom = LiveKit.create(
            appContext,
            overrides = LiveKitOverrides(audioOptions = AudioOptions(audioHandler = audioHandler)),
        )
        nextRoom.localParticipant.audioTrackCaptureDefaults = audioCaptureProfile.capturePolicy.toTrackOptions()
        nextRoom.localParticipant.audioTrackPublishDefaults = audioTrackPublishDefaults(audioBitratePreset)
        inputGainProcessor?.let {
            nextRoom.audioProcessingController.capturePostProcessor = it
            nextRoom.audioProcessingController.bypassCapturePostProcessing = false
        }
        room = nextRoom
        val endpoint = liveKitEndpointDiagnostic(url)
        _snapshot.value = LiveKitSnapshot(
            connectionState = IntercomConnectionState.CONNECTING,
            roomName = roomName,
            deployment = endpoint.deployment,
            endpointHost = endpoint.host,
            effectiveAudioBitrateKbps =
                nextRoom.localParticipant.audioTrackPublishDefaults.audioBitrate?.div(1_000),
        )
        eventJob = scope.launch {
            nextRoom.events.collect { event -> handleEvent(event) }
        }
        try {
            nextRoom.connect(url, token)
            if (canPublish) {
                // Prepare capture without publishing. The first actual publish occurs only
                // after the floor grant and start cue have completed.
                prewarmedTrack = nextRoom.localParticipant.getOrCreateDefaultAudioTrack().also { it.prewarm() }
                _snapshot.value = _snapshot.value.copy(microphoneTrackState = "prepared_muted")
            }
            refreshParticipants(nextRoom)
            _snapshot.value = _snapshot.value.copy(connectionState = IntercomConnectionState.CONNECTED)
        } catch (error: Throwable) {
            _snapshot.value = _snapshot.value.copy(
                connectionState = IntercomConnectionState.DISCONNECTED,
                lastError = error.message ?: "LiveKit connection failed",
            )
            disconnect()
            throw error
        }
    }

    fun setAudioCaptureProfile(profile: AudioCaptureProfile): Result<Unit> {
        if (microphoneEnabled) {
            return Result.failure(IllegalStateException("Audio capture profile cannot change during TX"))
        }
        val current = room
        if (current == null) {
            audioCaptureProfile = profile
            return Result.success(Unit)
        }
        val options = profile.capturePolicy.toTrackOptions()
        val track = prewarmedTrack
            ?: return Result.failure(IllegalStateException("Prepared microphone track is unavailable"))
        return track.applyOptions(options).onSuccess {
            current.localParticipant.audioTrackCaptureDefaults = options
            audioCaptureProfile = profile
            _snapshot.value = _snapshot.value.copy(microphoneTrackState = "prepared_muted:${profile.name}")
        }
    }

    override suspend fun setEnabled(enabled: Boolean): Boolean {
        val current = room ?: return false
        if (!enabled && !microphoneEnabled) return true
        return try {
            val changed = current.localParticipant.setMicrophoneEnabled(enabled)
            if (changed) {
                microphoneEnabled = enabled
                _snapshot.value = _snapshot.value.copy(
                    microphoneTrackState = if (enabled) "publishing" else "muted",
                )
            } else if (!enabled) {
                // A failed transition from a known transmitting state is unsafe.
                disconnect()
            }
            changed
        } catch (error: Throwable) {
            if (!enabled) disconnect()
            throw error
        }
    }

    override suspend fun publishStart(leaseId: String): Result<Unit> = publishControl("start", leaseId)

    override suspend fun publishBufferedStart(leaseId: String, generationId: String): Result<Unit> =
        publishControl("start", leaseId, generationId)

    override suspend fun publishEnd(leaseId: String): Result<Unit> = publishControl("end", leaseId)

    override fun prepareRxReady(leaseId: String, expectedSessionIds: List<String>) {
        prepareRxReady(leaseId, expectedSessionIds, emptyList())
    }

    override fun prepareRxReady(
        leaseId: String,
        expectedSessionIds: List<String>,
        expectedDeviceIds: List<String>,
    ) {
        rxReadyReconcileJob?.cancel()
        rxReadyReconcileJob = null
        rxReadyBarrier?.cancel()
        val currentChannel = channelId ?: return
        val currentSession = sessionId ?: return
        rxReadyLeaseId = leaseId
        val warmReadyDevices = room?.remoteParticipants?.values
            ?.mapNotNull { rxReadyCapableDeviceId(it.metadata) }
            .orEmpty()
        val expected = expectedSessionIds
            .map(String::trim)
            .filter { it.isNotBlank() && it != currentSession }
            .distinct()
        val expectedDevices = (expectedDeviceIds + warmReadyDevices)
            .map(String::trim)
            .filter { it.isNotBlank() && it != deviceId }
            .distinct()
        rxReadyBarrier = RxReadyBarrier(
            expectedSessionIds = expected,
            expectedDeviceIds = expectedDevices,
            channelId = currentChannel,
            speakerSessionId = currentSession,
            leaseId = leaseId,
        )
        _snapshot.value = _snapshot.value.copy(
            rxReadyExpectedCount = rxReadyBarrier?.expectedCount() ?: 0,
            rxReadyReceivedCount = 0,
            rxReadyLateCount = 0,
        )
    }

    override suspend fun awaitRxReady(leaseId: String): RxReadyResult {
        val barrier = rxReadyBarrier
        if (barrier == null || rxReadyLeaseId != leaseId) {
            return RxReadyResult(RxReadyReason.NO_EXPECTATIONS, 0, 0, 1.0, 0, 0)
        }
        val result = barrier.waitForReady()
        applyRxReadyBarrierSnapshot(barrier)
        _snapshot.value = _snapshot.value.copy(
            rxReadyExpectedCount = result.expectedCount,
            rxReadyReceivedCount = result.receivedCountAtMicOn,
            rxReadyLateCount = result.lateCount,
        )
        return result
    }

    override fun cancelRxReady() {
        rxReadyReconcileJob?.cancel()
        rxReadyReconcileJob = null
        rxReadyBarrier?.cancel()
        rxReadyBarrier = null
        rxReadyLeaseId = null
    }

    fun validateAudioRecovery(): Result<Unit> {
        val current = room ?: return Result.failure(IllegalStateException("LiveKit Room is unavailable"))
        if (_snapshot.value.connectionState != IntercomConnectionState.CONNECTED) {
            return Result.failure(IllegalStateException("LiveKit Room is not connected"))
        }
        refreshParticipants(current)
        _snapshot.value = _snapshot.value.copy(
            audioFocusState = "Granted / RX validated",
            remoteAudioState = if (_snapshot.value.remoteAudioTracks > 0) "subscribed" else "ready_no_remote_track",
        )
        return Result.success(Unit)
    }

    fun reconcileRxFloor(floor: FloorResponse) {
        rxAudio?.reconcileFloor(floor)
    }

    private suspend fun publishControl(type: String, leaseId: String, bufferedGenerationId: String? = null): Result<Unit> {
        val currentRoom = room ?: return Result.failure(IllegalStateException("LiveKit Room is unavailable"))
        val currentChannel = channelId ?: return Result.failure(IllegalStateException("Channel is unavailable"))
        val currentUser = userId ?: return Result.failure(IllegalStateException("User is unavailable"))
        val currentSession = sessionId ?: return Result.failure(IllegalStateException("Session is unavailable"))
        val event = PttControlEvent(
            type = type,
            channelId = currentChannel,
            speakerUserId = currentUser,
            sessionId = currentSession,
            leaseId = leaseId,
            sequence = ++controlSequence,
            sentAt = System.currentTimeMillis(),
            bufferedGenerationId = bufferedGenerationId,
        )
        val data = pttControlJson.encodeToString(event).encodeToByteArray()
        if (type == "start") {
            currentRoom.localParticipant.publishData(
                data,
                reliability = DataPublishReliability.LOSSY,
                topic = PTT_CONTROL_FAST_START_TOPIC,
            )
        }
        return currentRoom.localParticipant.publishData(
            data,
            reliability = DataPublishReliability.RELIABLE,
            topic = PTT_CONTROL_TOPIC,
        )
    }

    fun disconnect() {
        runCatching { prewarmedTrack?.stopPrewarm() }
        prewarmedTrack = null
        microphoneEnabled = false
        rxAudio?.reset()
        rxAudio = null
        cancelRxReady()
        rxReadyPublishLeaseId = null
        rxReadyStartLeaseId = null
        channelId = null
        userId = null
        sessionId = null
        deviceId = null
        controlSequence = 0
        room?.release()
        room = null
        eventJob?.cancel()
        eventJob = null
        _snapshot.value = LiveKitSnapshot()
    }

    private fun handleEvent(event: RoomEvent) {
        when (event) {
            is RoomEvent.Connected -> {
                refreshParticipants(event.room)
                _snapshot.value = _snapshot.value.copy(connectionState = IntercomConnectionState.CONNECTED)
            }
            is RoomEvent.Reconnecting -> {
                _snapshot.value = _snapshot.value.copy(connectionState = IntercomConnectionState.RECONNECTING)
            }
            is RoomEvent.Reconnected -> {
                refreshParticipants(event.room)
                _snapshot.value = _snapshot.value.copy(
                    connectionState = IntercomConnectionState.CONNECTED,
                    reconnectCount = _snapshot.value.reconnectCount + 1,
                )
            }
            is RoomEvent.Disconnected -> {
                cancelRxReady()
                _snapshot.value = _snapshot.value.copy(
                    connectionState = IntercomConnectionState.DISCONNECTED,
                    participantNames = emptyList(),
                    activeSpeaker = null,
                    lastError = event.error?.message,
                )
            }
            is RoomEvent.ParticipantConnected -> {
                refreshParticipants(event.room)
                reconcilePendingRxReady(
                    event.participant.identity?.value,
                    event.participant.metadata?.let(::participantDeviceId),
                    RxReadyReconcileSource.PARTICIPANT_CONNECTED,
                )
            }
            is RoomEvent.ParticipantMetadataChanged -> {
                refreshParticipants(event.room)
                reconcilePendingRxReady(
                    event.participant.identity?.value,
                    event.participant.metadata?.let(::participantDeviceId),
                    RxReadyReconcileSource.PARTICIPANT_METADATA_CHANGED,
                )
            }
            is RoomEvent.ParticipantDisconnected -> {
                rxReadyBarrier?.discardPendingParticipant(event.participant.identity?.value)
                rxReadyBarrier?.let(::applyRxReadyBarrierSnapshot)
                refreshParticipants(event.room)
            }
            is RoomEvent.ActiveSpeakersChanged -> {
                val remote = event.speakers.firstOrNull { it is io.livekit.android.room.participant.RemoteParticipant }
                rxAudio?.handleRemoteAudioActivity(remote?.identity?.value, remote != null)
                _snapshot.value = _snapshot.value.copy(
                    activeSpeaker = event.speakers.firstOrNull()?.displayName(),
                )
            }
            is RoomEvent.DataReceived -> {
                when (event.topic) {
                    PTT_CONTROL_TOPIC, PTT_CONTROL_FAST_START_TOPIC -> {
                        val control = runCatching {
                            pttControlJson.decodeFromString<PttControlEvent>(event.data.decodeToString())
                        }.getOrNull() ?: return
                        if (event.topic != PTT_CONTROL_FAST_START_TOPIC || control.type == "start") {
                            val participantIdentity = event.participant?.identity?.value
                            if (control.type == "start") {
                                if (rxReadyStartLeaseId != control.leaseId) {
                                    rxReadyStartLeaseId = control.leaseId
                                    _snapshot.value = _snapshot.value.copy(
                                        rxReadyStartReceivedAt = Instant.now(),
                                        rxReadyStartArmedAt = null,
                                        rxReadySenderIdentityPresent = participantIdentity != null,
                                        rxReadyReceiverDeviceIdPresent = deviceId != null,
                                        rxReadyPublishAttemptedAt = null,
                                        rxReadyPublishedAt = null,
                                        rxReadyPublishResult = "NOT_ATTEMPTED",
                                        rxReadyPublishFailureClass = null,
                                    )
                                } else {
                                    _snapshot.value = _snapshot.value.copy(
                                        rxReadySenderIdentityPresent =
                                            _snapshot.value.rxReadySenderIdentityPresent == true || participantIdentity != null,
                                        rxReadyReceiverDeviceIdPresent = deviceId != null,
                                    )
                                }
                            }
                            val startArmed = rxAudio?.handleControl(control, participantIdentity) == true
                            if (control.type == "start") control.bufferedGenerationId?.let(onBufferedAudioStart)
                            if (startArmed && participantIdentity != null) {
                                _snapshot.value = _snapshot.value.copy(rxReadyStartArmedAt = Instant.now())
                                publishReceiverReady(control, participantIdentity)
                            }
                        }
                    }
                    PTT_RX_READY_TOPIC -> {
                        val ready = runCatching {
                            pttRxReadyJson.decodeFromString<PttRxReadyEvent>(event.data.decodeToString())
                        }.getOrNull() ?: return
                        val barrier = rxReadyBarrier ?: return
                        val acceptance = barrier.acceptDetailed(
                            ready,
                            event.participant?.identity?.value,
                            event.participant?.metadata?.let(::participantDeviceId),
                        )
                        applyRxReadyBarrierSnapshot(barrier)
                        if (acceptance == RxReadyAcceptance.PENDING_PARTICIPANT_METADATA) {
                            refreshParticipants(event.room)
                            schedulePendingRxReadyReconciliation(event.room)
                        }
                    }
                }
            }
            is RoomEvent.ConnectionQualityChanged -> {
                if (event.participant == event.room.localParticipant) {
                    _snapshot.value = _snapshot.value.copy(connectionQuality = event.quality.name)
                }
            }
            is RoomEvent.TrackSubscribed -> {
                if (event.track is RemoteAudioTrack) {
                    _snapshot.value = _snapshot.value.copy(
                        remoteAudioTracks = _snapshot.value.remoteAudioTracks + 1,
                        remoteAudioState = "subscribed",
                    )
                }
            }
            is RoomEvent.TrackUnsubscribed -> {
                if (event.track is RemoteAudioTrack) {
                    _snapshot.value = _snapshot.value.copy(
                        remoteAudioTracks = (_snapshot.value.remoteAudioTracks - 1).coerceAtLeast(0),
                        remoteAudioState = if (_snapshot.value.remoteAudioTracks <= 1) "no_tracks" else "subscribed",
                    )
                }
            }
            is RoomEvent.TrackSubscriptionFailed -> {
                _snapshot.value = _snapshot.value.copy(
                    lastError = "Remote track subscription failed: ${event.exception.message ?: event.sid}",
                )
            }
            else -> Unit
        }
    }

    private fun reconcilePendingRxReady(
        participantIdentity: String?,
        participantDeviceId: String?,
        source: RxReadyReconcileSource,
    ) {
        val barrier = rxReadyBarrier ?: return
        barrier.reconcileParticipant(participantIdentity, participantDeviceId, source)
        applyRxReadyBarrierSnapshot(barrier)
    }

    private fun schedulePendingRxReadyReconciliation(currentRoom: Room) {
        val barrier = rxReadyBarrier ?: return
        if (!barrier.hasPendingMetadata()) return
        rxReadyReconcileJob?.cancel()
        rxReadyReconcileJob = scope.launch {
            while (isActive && rxReadyBarrier === barrier && barrier.hasPendingMetadata()) {
                currentRoom.remoteParticipants.values.forEach { participant ->
                    barrier.reconcileParticipant(
                        participant.identity?.value,
                        participant.metadata?.let(::participantDeviceId),
                        RxReadyReconcileSource.BOUNDED_POLL,
                    )
                }
                applyRxReadyBarrierSnapshot(barrier)
                if (!barrier.hasPendingMetadata()) break
                val remaining = barrier.remainingMs()
                if (remaining <= 0L) {
                    barrier.expirePendingAtDeadline()
                    applyRxReadyBarrierSnapshot(barrier)
                    break
                }
                delay(minOf(75L, remaining))
            }
        }
    }

    private fun applyRxReadyBarrierSnapshot(barrier: RxReadyBarrier) {
        val audit = barrier.auditSnapshot()
        _snapshot.value = _snapshot.value.copy(
            rxReadyExpectedCount = barrier.expectedCount(),
            rxReadyReceivedCount = barrier.receivedCount(),
            rxReadyLateCount = barrier.lateCount(),
            rxReadyReceivedEvents = audit.receivedEvents,
            rxReadyRejectedCount = audit.rejectedEvents,
            rxReadyRejectedSessionMismatch = audit.rejectedSessionMismatch,
            rxReadyRejectedDeviceMismatch = audit.rejectedDeviceMismatch,
            rxReadyRejectedParticipantMetadataMissing = audit.rejectedParticipantMetadataMissing,
            rxReadyRejectedLeaseMismatch = audit.rejectedLeaseMismatch,
            rxReadyRejectedChannelMismatch = audit.rejectedChannelMismatch,
            rxReadyRejectedDuplicate = audit.rejectedDuplicate,
            rxReadyRejectedDeadlineExpired = audit.rejectedDeadlineExpired,
            rxReadyPendingMetadataCount = audit.pendingMetadataCount,
            rxReadyPendingMetadataEvents = audit.pendingMetadataEvents,
            rxReadyPendingOldestAgeMs = audit.pendingOldestAgeMs,
            rxReadyPendingMaximumObservedAgeMs = audit.pendingMaximumObservedAgeMs,
            rxReadyBarrierStartedAtElapsedRealtimeMs = audit.barrierStartedAtElapsedRealtimeMs,
            rxReadyBarrierDeadlineAtElapsedRealtimeMs = audit.barrierDeadlineAtElapsedRealtimeMs,
            rxReadyMetadataAvailableAt = audit.metadataAvailableAtMs?.let(Instant::ofEpochMilli),
            rxReadyLastReconcileSource = audit.lastReconcileSource?.name,
            rxReadyTimeoutReason = audit.completionReason
                ?.takeIf { it == RxReadyReason.SINGLE_TIMEOUT || it == RxReadyReason.MULTI_TIMEOUT }
                ?.name,
            rxReadyFirstEventReceivedAt = audit.firstEventReceivedAtMs?.let(Instant::ofEpochMilli),
            rxReadyFirstAcceptedAt = audit.firstAcceptedAtMs?.let(Instant::ofEpochMilli),
        )
    }

    private fun refreshParticipants(currentRoom: Room) {
        val names = buildList {
            add(currentRoom.localParticipant.displayName())
            addAll(currentRoom.remoteParticipants.values.map { it.displayName() })
        }.filter { it.isNotBlank() }.distinct().sorted()
        _snapshot.value = _snapshot.value.copy(participantNames = names)
    }

    private fun io.livekit.android.room.participant.Participant.displayName(): String =
        name?.takeIf { it.isNotBlank() } ?: identity?.value.orEmpty()

    private fun participantDeviceId(metadata: String): String? = runCatching {
        pttRxReadyJson.parseToJsonElement(metadata).jsonObject["deviceId"]?.jsonPrimitive?.contentOrNull
    }.getOrNull()?.takeIf(String::isNotBlank)

    private fun publishReceiverReady(control: PttControlEvent, participantIdentity: String) {
        val currentRoom = room ?: return
        val currentChannel = channelId ?: return
        val currentSession = sessionId ?: return
        val currentDevice = deviceId ?: return
        if (
            currentRoom.state != Room.State.CONNECTED ||
            control.type != "start" ||
            control.channelId != currentChannel ||
            control.sessionId != participantIdentity
        ) return
        val ready = PttRxReadyEvent(
            channelId = currentChannel,
            speakerSessionId = participantIdentity,
            receiverSessionId = currentSession,
            receiverDeviceId = currentDevice,
            leaseId = control.leaseId,
            readyAt = System.currentTimeMillis(),
        )
        rxReadyPublishLeaseId = control.leaseId
        _snapshot.value = _snapshot.value.copy(
            rxReadyProtocolVersion = PTT_RX_READY_VERSION,
            rxReadyPublishAttemptedAt = Instant.now(),
            rxReadyPublishedAt = null,
            rxReadyPublishResult = "PENDING",
            rxReadyPublishFailureClass = null,
        )
        scope.launch {
            try {
                currentRoom.localParticipant.publishData(
                    pttRxReadyJson.encodeToString(ready).encodeToByteArray(),
                    reliability = DataPublishReliability.RELIABLE,
                    topic = PTT_RX_READY_TOPIC,
                )
                if (rxReadyPublishLeaseId == control.leaseId) {
                    _snapshot.value = _snapshot.value.copy(
                        rxReadyPublishedAt = Instant.now(),
                        rxReadyPublishResult = "SUCCESS",
                        rxReadyPublishFailureClass = null,
                    )
                }
            } catch (error: Throwable) {
                if (rxReadyPublishLeaseId == control.leaseId) {
                    _snapshot.value = _snapshot.value.copy(
                        rxReadyPublishedAt = null,
                        rxReadyPublishResult = "FAILURE",
                        rxReadyPublishFailureClass = rxReadyPublishFailureClass(error),
                    )
                }
            }
        }
    }

}

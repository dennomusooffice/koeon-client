package com.dennomuso.koeon.core.session

import android.content.Context
import android.media.AudioManager
import android.view.KeyEvent
import com.dennomuso.koeon.BuildConfig
import com.dennomuso.koeon.core.api.HttpKoeonApi
import com.dennomuso.koeon.core.api.KoeonApi
import com.dennomuso.koeon.core.api.KoeonApiException
import com.dennomuso.koeon.core.enrollment.EnrollmentCredential
import com.dennomuso.koeon.core.enrollment.EnrollmentInputParser
import com.dennomuso.koeon.core.auth.AndroidKeystoreDeviceCredentialStore
import com.dennomuso.koeon.core.auth.DeviceCredentialStore
import com.dennomuso.koeon.core.auth.AndroidDeviceDisplayNameStore
import com.dennomuso.koeon.core.audio.AudioRouteMonitor
import com.dennomuso.koeon.core.audio.AudioAvailabilityState
import com.dennomuso.koeon.core.audio.AudioInterruptionStateMachine
import com.dennomuso.koeon.core.audio.TonePttCuePlayer
import com.dennomuso.koeon.core.audio.AudioDeviceProfileStore
import com.dennomuso.koeon.core.audio.InputGainMode
import com.dennomuso.koeon.core.audio.InputGainProcessor
import com.dennomuso.koeon.core.audio.InputGainSnapshot
import com.dennomuso.koeon.core.audio.AudioBitratePreset
import com.dennomuso.koeon.core.audio.AudioBitratePreferenceStore
import com.dennomuso.koeon.core.audio.BufferedAudioTxDiagnostics
import com.dennomuso.koeon.core.audio.BufferedAudioRxDiagnostics
import com.dennomuso.koeon.core.audio.AUDIO_BITRATE_PREFERENCE_KEY
import com.dennomuso.koeon.core.livekit.IntercomConnectionState
import com.dennomuso.koeon.core.livekit.AudioFocusEvent
import com.dennomuso.koeon.core.livekit.AudioCaptureProfile
import com.dennomuso.koeon.core.livekit.LiveKitRoomController
import com.dennomuso.koeon.core.livekit.productionAudioCaptureProfile
import com.dennomuso.koeon.core.haptics.HapticSnapshot
import com.dennomuso.koeon.core.network.NetworkMonitor
import com.dennomuso.koeon.core.model.FixtureResponse
import com.dennomuso.koeon.core.model.Channel
import com.dennomuso.koeon.core.model.EnrollmentRequest
import com.dennomuso.koeon.core.model.MeResponse
import com.dennomuso.koeon.core.model.Tenant
import com.dennomuso.koeon.core.model.User
import com.dennomuso.koeon.core.model.Workspace
import com.dennomuso.koeon.core.model.FloorResponse
import com.dennomuso.koeon.core.model.JoinResponse
import com.dennomuso.koeon.core.model.Role
import com.dennomuso.koeon.core.ptt.FLOOR_LEASE_TTL_MS
import com.dennomuso.koeon.core.ptt.FLOOR_RENEW_INTERVAL_MS
import com.dennomuso.koeon.core.ptt.FloorGateway
import com.dennomuso.koeon.core.ptt.MAX_CONTINUOUS_TX_MS
import com.dennomuso.koeon.core.ptt.PttController
import com.dennomuso.koeon.core.ptt.AppTouchPttGate
import com.dennomuso.koeon.core.ptt.PttInputSource
import com.dennomuso.koeon.core.ptt.OrderedPttInputCommand
import com.dennomuso.koeon.core.ptt.OrderedPttInputQueue
import com.dennomuso.koeon.core.ptt.HardwareVolumeAction
import com.dennomuso.koeon.core.ptt.HardwareVolumePttGate
import com.dennomuso.koeon.core.ptt.HardwareVolumePttMode
import com.dennomuso.koeon.core.ptt.HardwareVolumePttEligibility
import com.dennomuso.koeon.core.ptt.PttSnapshot
import com.dennomuso.koeon.core.ptt.PttState
import com.dennomuso.koeon.core.ptt.localPttEligible
import com.dennomuso.koeon.core.ptt.RxSnapshot
import com.dennomuso.koeon.core.ptt.SystemPttClock
import com.dennomuso.koeon.service.IntercomForegroundService
import com.dennomuso.koeon.service.HeadsetPttAction
import com.dennomuso.koeon.service.HeadsetPttEligibility
import com.dennomuso.koeon.service.HeadsetPttMode
import com.dennomuso.koeon.service.RouteLossPttAction
import com.dennomuso.koeon.service.routeLossPttAction
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant

data class SessionDiagnostics(
    val leaseTtlMs: Long = FLOOR_LEASE_TTL_MS,
    val renewIntervalMs: Long = FLOOR_RENEW_INTERVAL_MS,
    val maxContinuousTxMs: Long = MAX_CONTINUOUS_TX_MS,
    val leaseExpiresAt: String? = null,
    val maxTxExpiresAt: String? = null,
    val audioRoute: String = "Unavailable",
    val remoteAudioTracks: Int = 0,
    val reconnectCount: Int = 0,
    val sessionUptimeSeconds: Long = 0,
    val connectionQuality: String = "Unavailable",
    val audioFocus: String = "Inactive",
    val network: String = "Unavailable",
    val foregroundService: String = "Inactive",
    val connectionLostAt: String? = null,
    val connectionRestoredAt: String? = null,
    val reconnectRecoveryMs: Long? = null,
    val networkChangedAt: String? = null,
    val audioRouteChangedAt: String? = null,
    val device: String = "Android ${android.os.Build.VERSION.RELEASE} / ${android.os.Build.MODEL}",
    val rtt: String = "Unavailable",
    val jitter: String = "Unavailable",
    val packetLoss: String = "Unavailable",
    val rx: RxSnapshot = RxSnapshot(),
    val hapticSupported: Boolean = false,
    val hapticEnabled: Boolean = false,
    val lastHapticType: String? = null,
    val lastHapticAt: String? = null,
    val lastHapticResult: String = "not_played",
    val audioAvailabilityState: AudioAvailabilityState = AudioAvailabilityState.READY,
    val interruptionStartedAt: String? = null,
    val interruptionEndedAt: String? = null,
    val interruptionReason: String? = null,
    val microphoneTrackState: String = "not_published",
    val remoteAudioState: String = "no_tracks",
    val recoveryStartedAt: String? = null,
    val recoveryCompletedAt: String? = null,
    val recoveryMs: Long? = null,
    val autoRecoveryResult: String = "not_required",
    val lastRecoveryError: String? = null,
    val activityVisibility: String = "foreground",
    val foregroundServiceStartCount: Int = 0,
    val notificationUpdateCount: Int = 0,
    val mediaSessionActive: Boolean = false,
    val headsetPttEnabled: Boolean = false,
    val headsetPttMode: HeadsetPttMode = HeadsetPttMode.TOGGLE,
    val lastMediaKey: String? = null,
    val lastMediaKeyAction: String? = null,
    val audioRouteChangeReason: String? = null,
    val rxReadyExpectedCount: Int = 0,
    val rxReadyReceivedCount: Int = 0,
    val rxReadyLateCount: Int = 0,
    val rxReadyProtocolVersion: Int = 1,
    val rxReadyPublishAttemptedAt: String? = null,
    val rxReadyPublishedAt: String? = null,
    val rxReadyPublishResult: String = "NOT_ATTEMPTED",
    val rxReadyPublishFailureClass: String? = null,
    val rxReadyStartReceivedAt: String? = null,
    val rxReadyStartArmedAt: String? = null,
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
    val rxReadyPendingMetadataCount: Int = 0,
    val rxReadyFirstEventReceivedAt: String? = null,
    val rxReadyFirstAcceptedAt: String? = null,
    val lastPttInputSource: PttInputSource? = null,
    val appTouchPressed: Boolean = false,
    val appTouchDownCount: Int = 0,
    val appTouchUpCount: Int = 0,
    val appTouchCancelCount: Int = 0,
    val appTouchLastDownAt: String? = null,
    val appTouchLastUpAt: String? = null,
    val appTouchLastCancelReason: String? = null,
    val appTouchMoveCount: Int = 0,
    val appTouchCaptureStartedAt: String? = null,
    val appTouchCaptureEndedAt: String? = null,
    val appTouchLastTerminalReason: String? = null,
    val appTouchScrollSuppressedCount: Int = 0,
    val appTouchPointerIdPresent: Boolean = false,
    val headsetLatched: Boolean = false,
    val headsetRoutePresent: Boolean = false,
    val hardwareVolumePttMode: HardwareVolumePttMode = HardwareVolumePttMode.OFF,
    val hardwareVolumePttLatched: Boolean = false,
    val hardwareVolumeLastKey: String? = null,
    val hardwareVolumeLastEventAt: String? = null,
    val hardwareVolumeShortPressCount: Int = 0,
    val hardwareVolumeLongPressCount: Int = 0,
    val hardwareVolumePttToggleCount: Int = 0,
    val outputVolume: Int = 0,
    val outputVolumeMax: Int = 0,
    val inputGain: InputGainSnapshot = InputGainSnapshot(),
    val audioCaptureProfile: AudioCaptureProfile = productionAudioCaptureProfile,
    val audioBitratePreset: AudioBitratePreset = AudioBitratePreset.DEFAULT,
    val requestedAudioBitrateKbps: Int = AudioBitratePreset.DEFAULT.kilobitsPerSecond,
    val effectiveAudioBitrateKbps: Int? = null,
    val liveKitDeployment: String = "UNKNOWN",
    val liveKitEndpointHost: String? = null,
    val bufferedAudioTx: BufferedAudioTxDiagnostics = BufferedAudioTxDiagnostics(),
    val bufferedAudioRx: BufferedAudioRxDiagnostics = BufferedAudioRxDiagnostics(),
    val controlSenderIdentityResolution: String = "REJECTED",
)

data class IntercomUiState(
    val loading: Boolean = false,
    val fixture: FixtureResponse? = null,
    val identity: MeResponse? = null,
    val enrollmentRequired: Boolean = false,
    val joined: Boolean = false,
    val join: JoinResponse? = null,
    val connectionState: IntercomConnectionState = IntercomConnectionState.DISCONNECTED,
    val ptt: PttSnapshot = PttSnapshot(),
    val participants: List<String> = emptyList(),
    val currentSpeaker: String? = null,
    val diagnostics: SessionDiagnostics = SessionDiagnostics(),
    val error: String? = null,
    val operationalState: OperationalState = OperationalState.UNENROLLED,
)

fun IntercomSessionManager.fieldDiagnosticJson(): String = buildAndroidFieldDiagnostic(state.value)

enum class OperationalState {
    UNENROLLED,
    ENROLLED_POWERED_OFF,
    CONNECTING,
    ACTIVE,
    SWITCHING_CHANNEL,
    AUDIO_INTERRUPTED,
    RECOVERING_AUDIO,
    ERROR,
}

internal fun enrollmentFailureDiagnostic(source: String, error: Throwable): String {
    val transport = if (error is KoeonApiException) {
        buildString {
            append("HTTP ")
            append(error.statusCode)
            error.errorCode?.takeIf { it.isNotBlank() }?.let { append("/").append(it) }
        }
    } else {
        error.javaClass.simpleName.ifBlank { "Error" }
    }
    val detail = error.message?.takeIf { it.isNotBlank() } ?: "Enrollment failed"
    return "Device enrollment failed ($source, $transport): $detail"
}
internal fun shouldStopPttForSafety(state: PttState): Boolean =
    state == PttState.TRANSMITTING || state == PttState.REQUESTING_FLOOR

/**
 * Application-scoped session owner. Activity/ViewModel lifecycle changes do not tear down
 * the Room. A single instance is used because Floor and LiveKit state are session state.
 */
class IntercomSessionManager(
    private val appContext: Context,
    apiOverride: KoeonApi? = null,
    credentialStoreOverride: DeviceCredentialStore? = null,
) {
    private val credentialStore = credentialStoreOverride ?: AndroidKeystoreDeviceCredentialStore(appContext)
    private val deviceDisplayName = AndroidDeviceDisplayNameStore(appContext).getOrCreate()
    private val api: KoeonApi = apiOverride ?: HttpKoeonApi(
        BuildConfig.KOEON_BACKEND_URL,
        credentialProvider = { credentialStore.read() },
    )
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val operationMutex = Mutex()
    private val devicePreferences = appContext.getSharedPreferences("koeon_device_settings", Context.MODE_PRIVATE)
    private val audioBitrateStore = AudioBitratePreferenceStore(
        read = { devicePreferences.getString(AUDIO_BITRATE_PREFERENCE_KEY, null) },
        write = { devicePreferences.edit().putString(AUDIO_BITRATE_PREFERENCE_KEY, it).apply() },
    )
    private var audioBitratePreset = audioBitrateStore.load()
    private val audioInterruption = AudioInterruptionStateMachine(android.os.SystemClock::elapsedRealtime)
    private val gainProcessor = InputGainProcessor(
        AudioDeviceProfileStore(appContext.getSharedPreferences("koeon_audio_profiles", Context.MODE_PRIVATE)),
        initialMode = productionAudioCaptureProfile.koeonGainMode,
    )
    private val batv1Capture = com.dennomuso.koeon.core.audio.Batv1CaptureBuffer()
    private var batv1Transmitter: com.dennomuso.koeon.core.audio.HttpBufferedAudioTransmitter? = null
    private var batv1Receiver: com.dennomuso.koeon.core.audio.HttpBufferedAudioReceiver? = null
    private val room = LiveKitRoomController(appContext, scope, gainProcessor, batv1Capture) { event ->
        when (event) {
            is AudioFocusEvent.Lost -> handleAudioInterruption(event.reason)
            AudioFocusEvent.Gained -> handleAudioFocusRegained()
        }
    }
    private var audioCaptureProfile = productionAudioCaptureProfile
    private val audioRouteMonitor = AudioRouteMonitor(appContext)
    private val networkMonitor = NetworkMonitor(appContext)
    private var pttController: PttController? = null
    private val pttInputQueue = OrderedPttInputQueue(scope) { command ->
        when (command) {
            is OrderedPttInputCommand.Down -> pttController?.pressDown(command.canTransmit)
            OrderedPttInputCommand.Up -> pttController?.pressUp()
        }
    }
    private val appTouchPttGate = AppTouchPttGate()
    private val hardwareVolumePttGate = HardwareVolumePttGate()
    private val systemAudioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var statusJob: Job? = null
    private var uptimeJob: Job? = null
    private var sessionStartedAt = 0L
    private var stoppedForReconnect = false
    private var previousConnectionState = IntercomConnectionState.DISCONNECTED
    private var connectionLostElapsed: Long? = null
    private var previousNetwork = "Unavailable"
    private var previousAudioRoute = "Unavailable"
    private var audioRecoveryJob: Job? = null
    private var pttStoppedForAudioInterruption = false
    private var previousPttState = PttState.IDLE
    private var switchGeneration = 0L
    private var headsetPttEnabled = devicePreferences.getBoolean("headset_ptt_enabled", false)
    private var headsetPttMode = runCatching {
        HeadsetPttMode.valueOf(
            devicePreferences.getString("headset_ptt_mode", HeadsetPttMode.TOGGLE.name)!!,
        )
    }.getOrDefault(HeadsetPttMode.TOGGLE)
    private var hardwareVolumePttMode = runCatching {
        HardwareVolumePttMode.valueOf(devicePreferences.getString("hardware_volume_ptt_mode", HardwareVolumePttMode.OFF.name)!!)
    }.getOrDefault(HardwareVolumePttMode.OFF)

    private val _state = MutableStateFlow(IntercomUiState())
    val state: StateFlow<IntercomUiState> = _state.asStateFlow()

    init {
        _state.update { it.copy(diagnostics = it.diagnostics.copy(
            headsetPttEnabled = headsetPttEnabled,
            headsetPttMode = headsetPttMode,
            hardwareVolumePttMode = hardwareVolumePttMode,
            outputVolume = systemAudioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL),
            outputVolumeMax = systemAudioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL),
            inputGain = gainProcessor.snapshot(),
            audioCaptureProfile = audioCaptureProfile,
            audioBitratePreset = audioBitratePreset,
            requestedAudioBitrateKbps = audioBitratePreset.kilobitsPerSecond,
        )) }
        scope.launch {
            room.snapshot.collect { liveKit ->
                val now = Instant.now().toString()
                val enteredLoss = liveKit.connectionState in setOf(
                    IntercomConnectionState.RECONNECTING,
                    IntercomConnectionState.DISCONNECTED,
                ) && previousConnectionState !in setOf(
                    IntercomConnectionState.RECONNECTING,
                    IntercomConnectionState.DISCONNECTED,
                )
                val restored = liveKit.connectionState == IntercomConnectionState.CONNECTED &&
                    previousConnectionState in setOf(
                        IntercomConnectionState.RECONNECTING,
                        IntercomConnectionState.DISCONNECTED,
                    ) && connectionLostElapsed != null
                if (enteredLoss) connectionLostElapsed = android.os.SystemClock.elapsedRealtime()
                val recoveryMs = if (restored) {
                    android.os.SystemClock.elapsedRealtime() - (connectionLostElapsed ?: 0L)
                } else null
                _state.update {
                    it.copy(
                        connectionState = liveKit.connectionState,
                        participants = liveKit.participantNames,
                        currentSpeaker = it.currentSpeaker ?: liveKit.activeSpeaker,
                        diagnostics = it.diagnostics.copy(
                            reconnectCount = liveKit.reconnectCount,
                            connectionQuality = liveKit.connectionQuality,
                            audioFocus = liveKit.audioFocusState,
                            audioRoute = liveKit.audioRoute,
                            remoteAudioTracks = liveKit.remoteAudioTracks,
                            microphoneTrackState = liveKit.microphoneTrackState,
                            remoteAudioState = liveKit.remoteAudioState,
                            rxReadyExpectedCount = liveKit.rxReadyExpectedCount,
                            rxReadyReceivedCount = liveKit.rxReadyReceivedCount,
                            rxReadyLateCount = liveKit.rxReadyLateCount,
                            rxReadyProtocolVersion = liveKit.rxReadyProtocolVersion,
                            rxReadyPublishAttemptedAt = liveKit.rxReadyPublishAttemptedAt?.toString(),
                            rxReadyPublishedAt = liveKit.rxReadyPublishedAt?.toString(),
                            rxReadyPublishResult = liveKit.rxReadyPublishResult,
                            rxReadyPublishFailureClass = liveKit.rxReadyPublishFailureClass,
                            rxReadyStartReceivedAt = liveKit.rxReadyStartReceivedAt?.toString(),
                            rxReadyStartArmedAt = liveKit.rxReadyStartArmedAt?.toString(),
                            rxReadySenderIdentityPresent = liveKit.rxReadySenderIdentityPresent,
                            rxReadyReceiverDeviceIdPresent = liveKit.rxReadyReceiverDeviceIdPresent,
                            rxReadyReceivedEvents = liveKit.rxReadyReceivedEvents,
                            rxReadyRejectedCount = liveKit.rxReadyRejectedCount,
                            rxReadyRejectedSessionMismatch = liveKit.rxReadyRejectedSessionMismatch,
                            rxReadyRejectedDeviceMismatch = liveKit.rxReadyRejectedDeviceMismatch,
                            rxReadyRejectedParticipantMetadataMissing = liveKit.rxReadyRejectedParticipantMetadataMissing,
                            rxReadyRejectedLeaseMismatch = liveKit.rxReadyRejectedLeaseMismatch,
                            rxReadyRejectedChannelMismatch = liveKit.rxReadyRejectedChannelMismatch,
                            rxReadyRejectedDuplicate = liveKit.rxReadyRejectedDuplicate,
                            rxReadyPendingMetadataCount = liveKit.rxReadyPendingMetadataCount,
                            rxReadyFirstEventReceivedAt = liveKit.rxReadyFirstEventReceivedAt?.toString(),
                            rxReadyFirstAcceptedAt = liveKit.rxReadyFirstAcceptedAt?.toString(),
                            rx = liveKit.rx,
                            connectionLostAt = if (enteredLoss) now else it.diagnostics.connectionLostAt,
                            connectionRestoredAt = if (restored) now else it.diagnostics.connectionRestoredAt,
                            reconnectRecoveryMs = recoveryMs ?: it.diagnostics.reconnectRecoveryMs,
                            liveKitDeployment = liveKit.deployment,
                            liveKitEndpointHost = liveKit.endpointHost,
                            effectiveAudioBitrateKbps = liveKit.effectiveAudioBitrateKbps,
                            bufferedAudioTx = batv1Transmitter?.diagnostics() ?: it.diagnostics.bufferedAudioTx,
                            bufferedAudioRx = batv1Receiver?.diagnostics() ?: it.diagnostics.bufferedAudioRx,
                            controlSenderIdentityResolution = liveKit.controlSenderIdentityResolution,
                        ),
                        error = liveKit.lastError ?: it.error,
                    )
                }
                gainProcessor.setRoute(liveKit.audioRoute)
                refreshInputGainDiagnostics()
                if (_state.value.joined && liveKit.connectionState != previousConnectionState) {
                    val join = _state.value.join
                    if (join != null) {
                        val notificationState = when (liveKit.connectionState) {
                            IntercomConnectionState.CONNECTED -> "接続中"
                            IntercomConnectionState.RECONNECTING -> IntercomForegroundService.STATE_RECONNECTING
                            IntercomConnectionState.CONNECTING -> "接続しています"
                            IntercomConnectionState.DISCONNECTED -> IntercomForegroundService.STATE_RECONNECTING
                        }
                        IntercomForegroundService.update(
                            join.channel.name, join.canPublish, notificationState, headsetPttEnabled,
                        )
                    }
                }
                if (liveKit.connectionState == IntercomConnectionState.RECONNECTING && !stoppedForReconnect) {
                    stoppedForReconnect = true
                    scope.launch { stopPttForSafetyIfActive("LiveKit reconnecting; TX stopped") }
                } else if (liveKit.connectionState == IntercomConnectionState.CONNECTED) {
                    stoppedForReconnect = false
                } else if (liveKit.connectionState == IntercomConnectionState.DISCONNECTED && _state.value.joined) {
                    scope.launch { stopPttForSafetyIfActive("LiveKit disconnected; TX stopped") }
                }
                if (restored) connectionLostElapsed = null
                previousConnectionState = liveKit.connectionState
            }
        }
        scope.launch {
            audioRouteMonitor.route.collect { route ->
                val changed = route != previousAudioRoute && previousAudioRoute != "Unavailable"
                val headsetRoutePresent = route == "Bluetooth" || route == "Wired headset"
                if (!headsetRoutePresent) IntercomForegroundService.resetHeadsetLatch()
                _state.update {
                    it.copy(diagnostics = it.diagnostics.copy(
                        audioRoute = route,
                        headsetRoutePresent = headsetRoutePresent,
                        headsetLatched = if (headsetRoutePresent) it.diagnostics.headsetLatched else false,
                        audioRouteChangedAt = if (changed) Instant.now().toString() else it.diagnostics.audioRouteChangedAt,
                    ))
                }
                previousAudioRoute = route
            }
        }
        scope.launch {
            audioRouteMonitor.events.collect { event ->
                _state.update {
                    it.copy(diagnostics = it.diagnostics.copy(
                        audioRouteChangeReason = event.reason,
                        audioRouteChangedAt = Instant.now().toString(),
                    ))
                }
                val active = shouldStopPttForSafety(pttController?.current()?.state ?: PttState.IDLE)
                if (routeLossPttAction(event.lostExternalInputRoute, active) == RouteLossPttAction.STOP_TX) {
                    stopPttForSafetyIfActive("Headset route lost; TX stopped before microphone fallback")
                    _state.update { it.copy(error = "Headset disconnected during TX; press PTT again to use the new route") }
                }
                // RX deliberately stays connected; LiveKit AudioSwitch remains routing owner.
            }
        }
        scope.launch {
            networkMonitor.state.collect { network ->
                val changed = network != previousNetwork && previousNetwork != "Unavailable"
                _state.update {
                    it.copy(diagnostics = it.diagnostics.copy(
                        network = network,
                        networkChangedAt = if (changed) Instant.now().toString() else it.diagnostics.networkChangedAt,
                    ))
                }
                if (network == "Offline" && _state.value.joined) {
                    scope.launch { stopPttForSafetyIfActive("Network unavailable; TX stopped") }
                }
                previousNetwork = network
            }
        }
    }

    fun loadFixture() {
        scope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching { api.me() }
                .onSuccess { identity -> applyIdentity(identity) }
                .onFailure { error ->
                    if (error is KoeonApiException && error.statusCode == 401) credentialStore.clear()
                    _state.update { it.copy(loading = false, fixture = null, identity = null, enrollmentRequired = true, error = null) }
                }
        }
    }

    fun enroll(inviteTokenOrUrl: String) {
        val credential = runCatching { EnrollmentInputParser.parse(inviteTokenOrUrl) }.getOrElse { error ->
            _state.update { it.copy(loading = false, enrollmentRequired = true, error = error.message ?: "Invalid Invite") }
            return
        }
        enrollCredential(credential, source = "manual_input")
    }

    fun enrollDeepLinkToken(token: String) {
        enrollCredential(EnrollmentCredential.Token(token), source = "deep_link")
    }

    fun reportInviteDeepLinkError() {
        _state.update {
            it.copy(
                loading = false,
                enrollmentRequired = true,
                error = "Invite deep link rejected by strict origin/path/fragment validation",
            )
        }
    }

    fun reportEnrollmentScannerError(message: String) {
        _state.update { it.copy(error = "QR scanner: $message") }
    }

    private fun enrollCredential(credential: EnrollmentCredential, source: String) {
        scope.launch {
            _state.update { it.copy(loading = true, error = null) }
            runCatching {
                api.enroll(EnrollmentRequest(
                    token = (credential as? EnrollmentCredential.Token)?.value,
                    code = (credential as? EnrollmentCredential.Code)?.value,
                    platform = "android",
                    deviceName = deviceDisplayName,
                    osVersion = android.os.Build.VERSION.RELEASE.take(80),
                    appVersion = BuildConfig.VERSION_NAME.take(40),
                ))
            }.onSuccess { enrollment ->
                credentialStore.write(enrollment.deviceCredential)
                applyIdentity(enrollment.identity)
            }.onFailure { error ->
                _state.update {
                    it.copy(
                        loading = false,
                        enrollmentRequired = true,
                        error = enrollmentFailureDiagnostic(source, error),
                    )
                }
            }
        }
    }

    fun resetDeviceAssignment() {
        scope.launch {
            _state.update { it.copy(loading = true, error = null) }
            if (_state.value.joined) leave(powerOff = true)
            runCatching { api.logout() }
                .onSuccess {
                    credentialStore.clear()
                    _state.value = IntercomUiState(
                        enrollmentRequired = true,
                        operationalState = OperationalState.UNENROLLED,
                        diagnostics = SessionDiagnostics(
                            headsetPttEnabled = headsetPttEnabled,
                            headsetPttMode = headsetPttMode,
                            hardwareVolumePttMode = hardwareVolumePttMode,
                            inputGain = gainProcessor.snapshot(),
                            audioCaptureProfile = audioCaptureProfile,
                            audioBitratePreset = audioBitratePreset,
                            requestedAudioBitrateKbps = audioBitratePreset.kilobitsPerSecond,
                        ),
                    )
                }
                .onFailure { error ->
                    _state.update {
                        it.copy(
                            loading = false,
                            enrollmentRequired = false,
                            error = "ユーザー割当の解除に失敗しました。再試行してください: ${error.message ?: "Network error"}",
                        )
                    }
                }
        }
    }

    fun setHeadsetPttEnabled(enabled: Boolean) {
        headsetPttEnabled = enabled
        devicePreferences.edit().putBoolean("headset_ptt_enabled", enabled).apply()
        _state.update { it.copy(diagnostics = it.diagnostics.copy(headsetPttEnabled = enabled)) }
        _state.value.join?.let {
            IntercomForegroundService.update(it.channel.name, it.canPublish, "接続中", enabled)
        }
    }

    fun setHeadsetPttMode(mode: HeadsetPttMode) {
        headsetPttMode = mode
        IntercomForegroundService.resetHeadsetLatch()
        devicePreferences.edit().putString("headset_ptt_mode", mode.name).apply()
        _state.update { it.copy(diagnostics = it.diagnostics.copy(headsetPttMode = mode)) }
    }

    fun setHardwareVolumePttMode(mode: HardwareVolumePttMode) {
        if (mode == HardwareVolumePttMode.OFF && hardwareVolumePttGate.clear()) {
            pttUp(PttInputSource.HARDWARE_VOLUME_BUTTON)
        }
        hardwareVolumePttMode = mode
        devicePreferences.edit().putString("hardware_volume_ptt_mode", mode.name).apply()
        _state.update { it.copy(diagnostics = it.diagnostics.copy(
            hardwareVolumePttMode = mode,
            hardwareVolumePttLatched = hardwareVolumePttGate.isLatched(),
        )) }
    }

    /** Returns true only when KOEON intentionally owns this foreground key sequence. */
    fun onHardwareVolumeKey(keyCode: Int, event: KeyEvent): Boolean {
        val state = _state.value
        val eligible = HardwareVolumePttEligibility(
            mode = hardwareVolumePttMode,
            joined = state.joined,
            canPublish = state.join?.canPublish == true,
            audioReady = state.diagnostics.audioAvailabilityState == AudioAvailabilityState.READY,
            foreground = state.diagnostics.activityVisibility == "foreground",
        ).consumesVolumeKeys()
        if (!eligible || keyCode !in setOf(KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN)) return false
        val action = when (event.action) {
            KeyEvent.ACTION_DOWN -> hardwareVolumePttGate.keyDown(event.repeatCount)
            KeyEvent.ACTION_UP -> hardwareVolumePttGate.keyUp(event.isLongPress)
            else -> HardwareVolumeAction.IGNORE
        }
        val short = if (event.action == KeyEvent.ACTION_UP && action != HardwareVolumeAction.IGNORE) 1 else 0
        val long = if (event.action == KeyEvent.ACTION_UP && event.isLongPress) 1 else 0
        _state.update { current -> current.copy(diagnostics = current.diagnostics.copy(
            hardwareVolumePttLatched = hardwareVolumePttGate.isLatched(),
            hardwareVolumeLastKey = KeyEvent.keyCodeToString(keyCode),
            hardwareVolumeLastEventAt = Instant.now().toString(),
            hardwareVolumeShortPressCount = current.diagnostics.hardwareVolumeShortPressCount + short,
            hardwareVolumeLongPressCount = current.diagnostics.hardwareVolumeLongPressCount + long,
            hardwareVolumePttToggleCount = current.diagnostics.hardwareVolumePttToggleCount + short,
        )) }
        when (action) {
            HardwareVolumeAction.DOWN -> pttDown(PttInputSource.HARDWARE_VOLUME_BUTTON)
            HardwareVolumeAction.UP -> pttUp(PttInputSource.HARDWARE_VOLUME_BUTTON)
            HardwareVolumeAction.IGNORE -> Unit
        }
        return true
    }

    fun adjustOutputVolume(direction: Int) {
        systemAudioManager.adjustStreamVolume(
            AudioManager.STREAM_VOICE_CALL,
            if (direction < 0) AudioManager.ADJUST_LOWER else AudioManager.ADJUST_RAISE,
            AudioManager.FLAG_SHOW_UI,
        )
        _state.update { it.copy(diagnostics = it.diagnostics.copy(
            outputVolume = systemAudioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL),
            outputVolumeMax = systemAudioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL),
        )) }
    }

    fun setInputGainMode(mode: InputGainMode) { gainProcessor.setMode(mode); refreshInputGainDiagnostics() }

    fun setAudioBitratePreset(preset: AudioBitratePreset) {
        audioBitratePreset = preset
        audioBitrateStore.save(preset)
        _state.update { state ->
            state.copy(diagnostics = state.diagnostics.copy(
                audioBitratePreset = preset,
                requestedAudioBitrateKbps = preset.kilobitsPerSecond,
            ))
        }
    }

    fun setAudioCaptureProfile(profile: AudioCaptureProfile) {
        if (!BuildConfig.DEBUG) return
        val current = _state.value
        val eligible = current.joined &&
            current.connectionState == IntercomConnectionState.CONNECTED &&
            current.diagnostics.audioAvailabilityState == AudioAvailabilityState.READY &&
            current.ptt.state == PttState.IDLE
        if (!eligible || profile == audioCaptureProfile) return
        room.setAudioCaptureProfile(profile)
            .onSuccess {
                audioCaptureProfile = profile
                gainProcessor.setMode(profile.koeonGainMode)
                _state.update { it.copy(
                    error = null,
                    diagnostics = it.diagnostics.copy(
                        audioCaptureProfile = profile,
                        inputGain = gainProcessor.snapshot(),
                    ),
                ) }
            }
            .onFailure { error ->
                _state.update { it.copy(error = "Audio capture profile switch failed: ${error.message ?: "unknown error"}") }
            }
    }
    fun setManualInputGain(db: Float) { gainProcessor.setManualGainDb(db); refreshInputGainDiagnostics() }
    fun startInputCalibration() { gainProcessor.startCalibration(); refreshInputGainDiagnostics() }
    fun resetInputGainProfile() { gainProcessor.resetProfile(); refreshInputGainDiagnostics() }

    private fun refreshInputGainDiagnostics() {
        _state.update { it.copy(diagnostics = it.diagnostics.copy(inputGain = gainProcessor.snapshot())) }
    }

    fun setActivityVisibility(value: String) {
        val service = IntercomForegroundService.diagnostics()
        _state.update {
            it.copy(diagnostics = it.diagnostics.copy(
                activityVisibility = value,
                foregroundServiceStartCount = service.foregroundStartCount,
                notificationUpdateCount = service.notificationUpdateCount,
                mediaSessionActive = headsetPttEnabled && it.join?.canPublish == true && service.running,
            ))
        }
    }

    fun headsetPttEligibility(): HeadsetPttEligibility {
        val state = _state.value
        return HeadsetPttEligibility(
            settingEnabled = headsetPttEnabled,
            joined = state.joined,
            canPublish = state.join?.canPublish == true,
            audioReady = state.diagnostics.audioAvailabilityState == AudioAvailabilityState.READY,
            mode = headsetPttMode,
        )
    }

    fun onHeadsetPttAction(action: HeadsetPttAction, key: String, keyAction: String) {
        val service = IntercomForegroundService.diagnostics()
        _state.update {
            it.copy(diagnostics = it.diagnostics.copy(
                foregroundServiceStartCount = service.foregroundStartCount,
                notificationUpdateCount = service.notificationUpdateCount,
                mediaSessionActive = headsetPttEnabled && it.join?.canPublish == true && service.running,
                headsetPttEnabled = headsetPttEnabled,
                headsetPttMode = headsetPttMode,
                lastMediaKey = key,
                lastMediaKeyAction = keyAction,
            ))
        }
        when (action) {
            HeadsetPttAction.DOWN -> {
                _state.update { it.copy(diagnostics = it.diagnostics.copy(headsetLatched = true)) }
                pttDown(PttInputSource.HEADSET_MEDIA_BUTTON)
            }
            HeadsetPttAction.UP -> {
                _state.update { it.copy(diagnostics = it.diagnostics.copy(headsetLatched = false)) }
                pttUp(PttInputSource.HEADSET_MEDIA_BUTTON)
            }
            HeadsetPttAction.IGNORE -> Unit
        }
    }

    private fun applyIdentity(identity: MeResponse) {
        val fixture = FixtureResponse(
            tenant = Tenant("authenticated", "KOEON"),
            workspace = Workspace(identity.workspace.id, "authenticated", identity.workspace.name),
            channels = identity.channels.map { Channel(it.id, identity.workspace.id, it.name) },
            users = listOf(User(
                id = identity.user.id,
                workspaceId = identity.workspace.id,
                name = identity.user.displayName,
                role = identity.user.role,
                channelIds = identity.channels.map { it.id },
            )),
        )
        _state.update { it.copy(loading = false, fixture = fixture, identity = identity, enrollmentRequired = false, error = null, operationalState = OperationalState.ENROLLED_POWERED_OFF) }
    }

    fun join(userId: String, channelId: String) {
        scope.launch { joinChannel(userId, channelId) }
    }

    private suspend fun joinChannel(userId: String, channelId: String): Boolean =
        operationMutex.withLock {
                if (_state.value.joined || _state.value.loading) return@withLock false
                val user = _state.value.fixture?.users?.firstOrNull { it.id == userId }
                val wantsToPublish = user?.role != Role.LISTENER
                _state.update {
                    it.copy(
                        loading = true,
                        connectionState = IntercomConnectionState.CONNECTING,
                        operationalState = OperationalState.CONNECTING,
                        error = null,
                    )
                }
                var joined: JoinResponse? = null
                try {
                    val channelName = _state.value.fixture?.channels?.firstOrNull { it.id == channelId }?.name ?: channelId
                    IntercomForegroundService.start(appContext, channelName, wantsToPublish, headsetPttEnabled)
                    joined = api.join(userId, channelId, wantsToPublish)
                    audioRouteMonitor.start()
                    networkMonitor.start()
                    room.connect(
                        joined.livekitUrl,
                        joined.token,
                        joined.roomName,
                        joined.canPublish,
                        joined.channel.id,
                        joined.user.id,
                        joined.sessionId,
                        joined.deviceId,
                        audioBitratePreset,
                    )
                    configurePtt(joined)
                    sessionStartedAt = android.os.SystemClock.elapsedRealtime()
                    startSessionPolling(joined)
                    _state.update {
                        it.copy(
                            loading = false,
                            joined = true,
                            join = joined,
                            diagnostics = it.diagnostics.copy(foregroundService = "Active"),
                            error = null,
                            operationalState = OperationalState.ACTIVE,
                        )
                    }
                    IntercomForegroundService.update(
                        joined.channel.name, joined.canPublish, "接続中", headsetPttEnabled,
                    )
                    true
                } catch (error: Throwable) {
                    room.disconnect()
                    audioRouteMonitor.stop()
                    networkMonitor.stop()
                    IntercomForegroundService.stop(appContext)
                    joined?.let { runCatching { api.leave(it.sessionId) } }
                    _state.update {
                        it.copy(
                            loading = false,
                            joined = false,
                            join = null,
                            connectionState = IntercomConnectionState.DISCONNECTED,
                            error = error.message ?: "Channel join failed",
                            operationalState = OperationalState.ERROR,
                        )
                    }
                    false
                }
        }

    fun leaveAsync() {
        scope.launch { leave(powerOff = true) }
    }

    suspend fun leave(powerOff: Boolean = true) {
        operationMutex.withLock {
            appTouchPttGate.cancel()
            hardwareVolumePttGate.clear()
            val join = _state.value.join
            statusJob?.cancel()
            uptimeJob?.cancel()
            audioRecoveryJob?.cancel()
            runCatching { pttController?.stopForSafety("Session left") }
            room.disconnect()
            audioRouteMonitor.stop()
            networkMonitor.stop()
            if (join != null) runCatching { api.leave(join.sessionId) }
            IntercomForegroundService.stop(appContext)
            pttController = null
            previousConnectionState = IntercomConnectionState.DISCONNECTED
            connectionLostElapsed = null
            previousNetwork = "Unavailable"
            previousAudioRoute = "Unavailable"
            audioInterruption.reset()
            pttStoppedForAudioInterruption = false
            _state.value = IntercomUiState(
                fixture = _state.value.fixture,
                identity = _state.value.identity,
                enrollmentRequired = false,
                operationalState = if (powerOff) OperationalState.ENROLLED_POWERED_OFF else OperationalState.SWITCHING_CHANNEL,
                diagnostics = SessionDiagnostics(
                    headsetPttEnabled = headsetPttEnabled,
                    headsetPttMode = headsetPttMode,
                    hardwareVolumePttMode = hardwareVolumePttMode,
                    inputGain = gainProcessor.snapshot(),
                    audioCaptureProfile = audioCaptureProfile,
                    audioBitratePreset = audioBitratePreset,
                    requestedAudioBitrateKbps = audioBitratePreset.kilobitsPerSecond,
                ),
            )
        }
    }

    fun switchChannel(targetChannelId: String) {
        val current = _state.value
        val previousChannelId = current.join?.channel?.id ?: return
        val userId = current.identity?.user?.id ?: current.join?.user?.id ?: return
        if (targetChannelId == previousChannelId || current.operationalState == OperationalState.SWITCHING_CHANNEL) return
        val assignedIds = current.identity?.channels?.map { it.id }
            ?: current.fixture?.users?.firstOrNull { it.id == userId }?.channelIds
            ?: emptyList()
        if (targetChannelId !in assignedIds) {
            _state.update { it.copy(error = "Channel is not assigned to this User") }
            return
        }
        val generation = ++switchGeneration
        _state.update { it.copy(operationalState = OperationalState.SWITCHING_CHANNEL, loading = true, error = null) }
        scope.launch {
            leave(powerOff = false)
            if (generation != switchGeneration) return@launch
            val switched = joinChannel(userId, targetChannelId)
            if (generation != switchGeneration) return@launch
            if (!switched) {
                val recovered = joinChannel(userId, previousChannelId)
                _state.update {
                    it.copy(error = if (recovered) {
                        "Target Channel join failed; previous Channel restored"
                    } else {
                        "Target Channel and previous Channel recovery failed"
                    })
                }
            }
        }
    }

    private fun pttDown(source: PttInputSource): Boolean {
        _state.update { it.copy(diagnostics = it.diagnostics.copy(lastPttInputSource = source)) }
        val remoteTalking = _state.value.currentSpeaker != null &&
            _state.value.ptt.state != PttState.TRANSMITTING
        val canTransmit = localPttEligible(
            operationallyActive = _state.value.operationalState == OperationalState.ACTIVE,
            canPublish = _state.value.join?.canPublish == true,
            connected = _state.value.connectionState == IntercomConnectionState.CONNECTED,
            audioReady = audioInterruption.snapshot.state == AudioAvailabilityState.READY,
            remoteTalking = remoteTalking,
        )
        if (!canTransmit && _state.value.join?.canPublish == true) {
            if (remoteTalking) {
                scope.launch { pttController?.rejectForRemoteBusy() }
            } else {
                _state.update { it.copy(error = "AUDIO INTERRUPTED: 音声復旧が完了するまでPTTは利用できません") }
                scope.launch { pttController?.rejectForAudioUnavailable() }
            }
            return false
        }
        return pttInputQueue.down(canTransmit)
    }

    fun retryAudioRecovery() {
        recoverAudio(audioInterruption.snapshot.generation)
    }

    private fun pttUp(source: PttInputSource) {
        _state.update { it.copy(diagnostics = it.diagnostics.copy(lastPttInputSource = source)) }
        pttInputQueue.up()
    }

    fun appTouchPttDown(pointerId: Long? = null): Boolean {
        if (!appTouchPttGate.down()) return false
        if (!pttDown(PttInputSource.APP_TOUCH)) {
            appTouchPttGate.cancel()
            return false
        }
        val occurredAt = Instant.now().toString()
        _state.update { it.copy(diagnostics = it.diagnostics.copy(
            lastPttInputSource = PttInputSource.APP_TOUCH,
            appTouchPressed = true,
            appTouchDownCount = it.diagnostics.appTouchDownCount + 1,
            appTouchLastDownAt = occurredAt,
            appTouchCaptureStartedAt = occurredAt,
            appTouchCaptureEndedAt = null,
            appTouchLastTerminalReason = null,
            appTouchPointerIdPresent = pointerId != null,
        )) }
        return true
    }

    fun appTouchPttUp(terminalReason: String = "PHYSICAL_UP"): Boolean {
        if (!appTouchPttGate.up()) return false
        val occurredAt = Instant.now().toString()
        _state.update { it.copy(diagnostics = it.diagnostics.copy(
            lastPttInputSource = PttInputSource.APP_TOUCH,
            appTouchPressed = false,
            appTouchUpCount = it.diagnostics.appTouchUpCount + 1,
            appTouchLastUpAt = occurredAt,
            appTouchCaptureEndedAt = occurredAt,
            appTouchLastTerminalReason = terminalReason,
            appTouchPointerIdPresent = false,
        )) }
        pttUp(PttInputSource.APP_TOUCH)
        return true
    }

    fun appTouchPttCancel(reason: String): Boolean {
        if (!appTouchPttGate.cancel()) return false
        _state.update { it.copy(diagnostics = it.diagnostics.copy(
            lastPttInputSource = PttInputSource.APP_TOUCH,
            appTouchPressed = false,
            appTouchCancelCount = it.diagnostics.appTouchCancelCount + 1,
            appTouchLastCancelReason = reason,
            appTouchCaptureEndedAt = Instant.now().toString(),
            appTouchLastTerminalReason = reason,
            appTouchPointerIdPresent = false,
        )) }
        pttUp(PttInputSource.APP_TOUCH)
        return true
    }

    fun appTouchPttMove(pointerId: Long) {
        if (!appTouchPttGate.isPressed()) return
        _state.update { it.copy(diagnostics = it.diagnostics.copy(
            appTouchMoveCount = it.diagnostics.appTouchMoveCount + 1,
            appTouchScrollSuppressedCount = it.diagnostics.appTouchScrollSuppressedCount + 1,
            appTouchPointerIdPresent = true,
        )) }
    }

    fun reportHaptic(snapshot: HapticSnapshot) {
        _state.update {
            it.copy(
                diagnostics = it.diagnostics.copy(
                    hapticSupported = snapshot.supported,
                    hapticEnabled = snapshot.enabled,
                    lastHapticType = snapshot.lastType?.name?.lowercase(),
                    lastHapticAt = snapshot.lastAtEpochMs?.let(Instant::ofEpochMilli)?.toString(),
                    lastHapticResult = snapshot.lastResult.diagnosticValue,
                ),
            )
        }
    }

    fun reportPermissionError(message: String) {
        _state.update { it.copy(error = message) }
    }

    fun onForegroundServiceDestroyed() {
        if (!_state.value.joined) return
        scope.launch {
            leave()
            _state.update { it.copy(error = "Foreground service stopped unexpectedly; session was closed safely") }
        }
    }

    private fun configurePtt(join: JoinResponse) {
        val floor = object : FloorGateway {
            override suspend fun acquire(): FloorResponse = api.acquire(join.sessionId)
            override suspend fun renew(leaseId: String): FloorResponse = api.renew(join.sessionId, leaseId)
            override suspend fun release(leaseId: String): FloorResponse = api.release(join.sessionId, leaseId)
        }
        val deviceId = join.deviceId
        batv1Receiver?.stop()
        batv1Receiver = com.dennomuso.koeon.core.audio.HttpBufferedAudioReceiver(scope, api, join.sessionId)
        room.onBufferedAudioStart = { generationId -> batv1Receiver?.start(generationId) }
        batv1Transmitter = if (join.canPublish && !deviceId.isNullOrBlank()) {
            com.dennomuso.koeon.core.audio.HttpBufferedAudioTransmitter(
                scope = scope,
                api = api,
                capture = batv1Capture,
                channelId = join.channel.id,
                sessionId = join.sessionId,
                deviceId = deviceId,
            )
        } else null
        pttController = PttController(
            scope = scope,
            floor = floor,
            microphone = room,
            cuePlayer = TonePttCuePlayer(appContext),
            control = room,
            bufferedAudio = batv1Transmitter,
            clock = SystemPttClock(),
            onSnapshot = { ptt ->
                if (ptt.state == PttState.TRANSMITTING && previousPttState != PttState.TRANSMITTING) {
                    gainProcessor.beginTransmission()
                } else if (ptt.state != PttState.TRANSMITTING && previousPttState == PttState.TRANSMITTING) {
                    gainProcessor.endTransmission()
                }
                previousPttState = ptt.state
                refreshInputGainDiagnostics()
                if (ptt.state !in setOf(PttState.REQUESTING_FLOOR, PttState.TRANSMITTING)) {
                    IntercomForegroundService.resetHeadsetLatch()
                }
                _state.update { it.copy(ptt = ptt, error = ptt.lastError ?: it.error) }
            },
        ).also {
            if (!join.canPublish) it.setRxOnly() else it.reset()
        }
    }

    private fun startSessionPolling(join: JoinResponse) {
        statusJob?.cancel()
        statusJob = scope.launch {
            while (true) {
                val floor = runCatching { api.floorStatus(join.sessionId) }.getOrNull()
                if (floor != null) {
                    room.reconcileRxFloor(floor)
                    _state.update {
                        it.copy(
                            currentSpeaker = floor.owner?.name,
                            diagnostics = it.diagnostics.copy(
                                leaseExpiresAt = floor.leaseExpiresAt,
                                maxTxExpiresAt = floor.maxTxExpiresAt,
                            ),
                        )
                    }
                }
                delay(1_000)
            }
        }
        uptimeJob?.cancel()
        uptimeJob = scope.launch {
            while (true) {
                val uptime = (android.os.SystemClock.elapsedRealtime() - sessionStartedAt).coerceAtLeast(0L) / 1_000L
                audioRouteMonitor.refresh()
                _state.update { it.copy(diagnostics = it.diagnostics.copy(
                    sessionUptimeSeconds = uptime,
                    bufferedAudioTx = batv1Transmitter?.diagnostics() ?: it.diagnostics.bufferedAudioTx,
                    bufferedAudioRx = batv1Receiver?.diagnostics() ?: it.diagnostics.bufferedAudioRx,
                )) }
                delay(1_000)
            }
        }
    }

    private suspend fun stopPttForSafetyIfActive(reason: String) {
        val touchCancelled = appTouchPttGate.cancel()
        hardwareVolumePttGate.clear()
        _state.update { it.copy(diagnostics = it.diagnostics.copy(
            lastPttInputSource = PttInputSource.SYSTEM_SAFETY,
            appTouchPressed = false,
            appTouchCancelCount = it.diagnostics.appTouchCancelCount + if (touchCancelled) 1 else 0,
            appTouchLastCancelReason = if (touchCancelled) reason else it.diagnostics.appTouchLastCancelReason,
            headsetLatched = false,
            hardwareVolumePttLatched = false,
        )) }
        IntercomForegroundService.resetHeadsetLatch()
        val controller = pttController ?: return
        if (shouldStopPttForSafety(controller.current().state)) {
            controller.stopForSafety(reason)
        }
    }

    private fun handleAudioInterruption(reason: String) {
        val previous = audioInterruption.snapshot
        audioInterruption.interrupt(reason)
        publishAudioInterruptionDiagnostics()
        if (previous.state == AudioAvailabilityState.INTERRUPTED) return
        val pttState = pttController?.current()?.state
        pttStoppedForAudioInterruption = pttStoppedForAudioInterruption ||
            shouldStopPttForSafety(pttState ?: PttState.IDLE)
        scope.launch { stopPttForSafetyIfActive("Audio focus lost; TX stopped and Floor released") }
        _state.update { it.copy(error = "AUDIO INTERRUPTED: System call or OS audio has priority") }
        audioRecoveryJob?.cancel()
    }

    private fun handleAudioFocusRegained() {
        if (!_state.value.joined || audioInterruption.snapshot.state == AudioAvailabilityState.READY) return
        recoverAudio(audioInterruption.snapshot.generation)
    }

    private fun recoverAudio(generation: Long) {
        if (!audioInterruption.beginRecovery(generation)) return
        publishAudioInterruptionDiagnostics()
        audioRecoveryJob?.cancel()
        audioRecoveryJob = scope.launch {
            val result = withTimeoutOrNull(5_000) {
                delay(100)
                room.validateAudioRecovery()
            } ?: Result.failure(IllegalStateException("Audio recovery timed out"))
            if (result.isSuccess) {
                if (audioInterruption.completeRecovery(generation)) {
                    publishAudioInterruptionDiagnostics()
                    if (pttStoppedForAudioInterruption && _state.value.join?.canPublish == true) {
                        pttController?.reset()
                    }
                    pttStoppedForAudioInterruption = false
                    _state.update { it.copy(error = null) }
                }
            } else {
                val message = result.exceptionOrNull()?.message ?: "Audio recovery failed"
                if (audioInterruption.failRecovery(generation, message)) {
                    publishAudioInterruptionDiagnostics()
                    _state.update { it.copy(error = "音声の自動復旧に失敗しました: $message") }
                }
            }
        }
    }

    private fun publishAudioInterruptionDiagnostics() {
        val audio = audioInterruption.snapshot
        fun timestamp(value: Long?): String? = value?.let {
            val wallClock = System.currentTimeMillis() - android.os.SystemClock.elapsedRealtime() + it
            Instant.ofEpochMilli(wallClock).toString()
        }
        _state.update {
            it.copy(diagnostics = it.diagnostics.copy(
                audioAvailabilityState = audio.state,
                interruptionStartedAt = timestamp(audio.interruptionStartedAtMs),
                interruptionEndedAt = timestamp(audio.interruptionEndedAtMs),
                interruptionReason = audio.interruptionReason,
                recoveryStartedAt = timestamp(audio.recoveryStartedAtMs),
                recoveryCompletedAt = timestamp(audio.recoveryCompletedAtMs),
                recoveryMs = audio.recoveryMs,
                autoRecoveryResult = audio.autoRecoveryResult,
                lastRecoveryError = audio.lastRecoveryError,
            ))
        }
    }
}

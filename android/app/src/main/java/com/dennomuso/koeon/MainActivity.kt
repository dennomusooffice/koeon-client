package com.dennomuso.koeon

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.content.Intent
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dennomuso.koeon.core.livekit.IntercomConnectionState
import com.dennomuso.koeon.core.enrollment.InviteDeepLinkRouter
import com.dennomuso.koeon.core.haptics.AndroidViewHapticPerformer
import com.dennomuso.koeon.core.haptics.PttHapticFeedbackController
import com.dennomuso.koeon.core.audio.AudioAvailabilityState
import com.dennomuso.koeon.core.ptt.PttState
import com.dennomuso.koeon.core.ptt.PttSemanticState
import com.dennomuso.koeon.core.ptt.isParentScrollEnabledWhileTouchPtt
import com.dennomuso.koeon.core.ptt.localPttEligible
import com.dennomuso.koeon.core.ptt.pttSemanticState
import com.dennomuso.koeon.core.permission.JoinPermissionPolicy
import com.dennomuso.koeon.core.session.IntercomSessionManager
import com.dennomuso.koeon.core.session.IntercomUiState
import com.dennomuso.koeon.core.session.ChannelSwitchPolicy
import com.dennomuso.koeon.core.session.OperationalState
import com.dennomuso.koeon.core.session.fieldDiagnosticJson
import com.dennomuso.koeon.service.HeadsetPttMode
import com.dennomuso.koeon.core.ptt.HardwareVolumePttMode
import com.dennomuso.koeon.core.audio.InputGainMode
import com.dennomuso.koeon.core.audio.AudioBitratePreset
import com.dennomuso.koeon.core.livekit.AudioCaptureProfile
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode

class MainActivity : ComponentActivity() {
    private lateinit var inviteRouter: InviteDeepLinkRouter

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val manager = (application as KoeonApplication).intercomSession
        inviteRouter = InviteDeepLinkRouter(manager::enrollDeepLinkToken)
        routeInviteIntent(manager, intent)
        setContent { KoeonApp(manager) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        routeInviteIntent((application as KoeonApplication).intercomSession, intent)
    }

    override fun onResume() {
        super.onResume()
        (application as KoeonApplication).intercomSession.setActivityVisibility("foreground")
    }

    override fun onStop() {
        (application as KoeonApplication).intercomSession.setActivityVisibility("background_or_locked")
        super.onStop()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val manager = (application as KoeonApplication).intercomSession
        if (manager.onHardwareVolumeKey(keyCode, event)) return true
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        val manager = (application as KoeonApplication).intercomSession
        if (manager.onHardwareVolumeKey(keyCode, event)) return true
        return super.onKeyUp(keyCode, event)
    }

    private fun routeInviteIntent(manager: IntercomSessionManager, intent: Intent?) {
        val inviteUrl = intent?.dataString ?: return
        if (!inviteRouter.route(inviteUrl)) manager.reportInviteDeepLinkError()
    }
}

private val KoeonBlack = Color(0xFF020D2C)
private val KoeonPanel = Color(0xFF06111F)
private val KoeonLcd = Color(0xFF031A20)
private val KoeonGreen = Color(0xFF22DFF3)
private val KoeonSuccess = Color(0xFF65DB68)
private val KoeonRed = Color(0xFFFF665E)

@Composable
private fun KoeonApp(manager: IntercomSessionManager) {
    val state by manager.state.collectAsStateWithLifecycle()
    MaterialTheme {
        Surface(color = KoeonBlack, contentColor = Color.White, modifier = Modifier.fillMaxSize()) {
            KoeonScreen(state, manager)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KoeonScreen(state: IntercomUiState, manager: IntercomSessionManager) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var selectedUserId by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedChannelId by rememberSaveable { mutableStateOf<String?>(null) }
    var userMenuOpen by remember { mutableStateOf(false) }
    var channelMenuOpen by remember { mutableStateOf(false) }
    var inviteInput by rememberSaveable { mutableStateOf("") }
    val selectedUser = state.fixture?.users?.firstOrNull { it.id == selectedUserId }
    val selectedChannel = state.fixture?.channels?.firstOrNull { it.id == selectedChannelId }

    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        val microphoneRequired = JoinPermissionPolicy.microphoneRequired(selectedUser?.role)
        val microphoneGranted = !microphoneRequired ||
            results[Manifest.permission.RECORD_AUDIO] == true ||
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED
        if (JoinPermissionPolicy.canJoin(selectedUser?.role, microphoneGranted) && selectedUserId != null && selectedChannelId != null) {
            manager.join(selectedUserId!!, selectedChannelId!!)
        } else {
            manager.reportPermissionError("Microphone permission is required for PTT")
        }
    }

    LaunchedEffect(Unit) { if (state.fixture == null && !state.loading) manager.loadFixture() }
    LaunchedEffect(state.identity) {
        state.identity?.let { identity ->
            selectedUserId = identity.user.id
            if (selectedChannelId !in identity.channels.map { it.id }) {
                selectedChannelId = identity.channels.firstOrNull()?.id
            }
        }
    }

    Column(
        modifier = Modifier.fillMaxSize()
            .verticalScroll(
                rememberScrollState(),
                enabled = isParentScrollEnabledWhileTouchPtt(state.diagnostics.appTouchPressed),
            )
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("KOEON", color = Color.White, fontSize = 34.sp, fontWeight = FontWeight.Black, letterSpacing = 2.sp)
        Text("声を、いつでもONに。", color = Color(0xFFB6C1BA))

        if (!state.joined) {
            if (state.enrollmentRequired) {
                Text("KOEONを利用登録", color = KoeonGreen, fontSize = 26.sp, fontWeight = FontWeight.Bold)
                Text("運営から届いた招待コードを入力してください。")
                OutlinedTextField(
                    value = inviteInput,
                    onValueChange = { inviteInput = it },
                    label = { Text("招待コード") },
                    placeholder = { Text("ABCDE-FGHIJ") },
                    modifier = Modifier.fillMaxWidth(),
                )
                Button(
                    onClick = { manager.enroll(inviteInput) },
                    enabled = inviteInput.trim().length >= 10 && !state.loading,
                    modifier = Modifier.fillMaxWidth().height(54.dp),
                ) { Text(if (state.loading) "登録中…" else "この端末を登録") }
                Text("QRコードを使う場合", color = Color(0xFFB6C1BA), fontSize = 14.sp)
                Button(
                    onClick = {
                        val options = GmsBarcodeScannerOptions.Builder()
                            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                            .enableAutoZoom()
                            .build()
                        GmsBarcodeScanning.getClient(context, options).startScan()
                            .addOnSuccessListener { barcode ->
                                barcode.rawValue?.let(manager::enroll)
                                    ?: manager.reportEnrollmentScannerError("QRにInvite情報がありません")
                            }
                            .addOnFailureListener { manager.reportEnrollmentScannerError(it.message ?: "読み取りに失敗しました") }
                    },
                    modifier = Modifier.fillMaxWidth().height(54.dp),
                ) { Text("QRコードを読み取る") }
            } else {
            ExposedDropdownMenuBox(expanded = userMenuOpen, onExpandedChange = { userMenuOpen = it }) {
                OutlinedTextField(
                    value = selectedUser?.name.orEmpty(),
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("User") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(userMenuOpen) },
                    modifier = Modifier.menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable).fillMaxWidth(),
                )
                ExposedDropdownMenu(expanded = userMenuOpen, onDismissRequest = { userMenuOpen = false }) {
                    state.fixture?.users?.forEach { user ->
                        DropdownMenuItem(
                            text = { Text("${user.name} · ${user.role}") },
                            onClick = {
                                selectedUserId = user.id
                                if (selectedChannelId !in user.channelIds) selectedChannelId = user.channelIds.firstOrNull()
                                userMenuOpen = false
                            },
                        )
                    }
                }
            }
            ExposedDropdownMenuBox(expanded = channelMenuOpen, onExpandedChange = { channelMenuOpen = it }) {
                OutlinedTextField(
                    value = selectedChannel?.name.orEmpty(),
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Channel") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(channelMenuOpen) },
                    modifier = Modifier.menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable).fillMaxWidth(),
                )
                ExposedDropdownMenu(expanded = channelMenuOpen, onDismissRequest = { channelMenuOpen = false }) {
                    state.fixture?.channels?.filter { selectedUser == null || it.id in selectedUser.channelIds }?.forEach { channel ->
                        DropdownMenuItem(
                            text = { Text(channel.name) },
                            onClick = { selectedChannelId = channel.id; channelMenuOpen = false },
                        )
                    }
                }
            }
            Button(
                onClick = {
                    val permissions = buildList {
                        if (JoinPermissionPolicy.microphoneRequired(selectedUser?.role)) add(Manifest.permission.RECORD_AUDIO)
                        if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
                        if (Build.VERSION.SDK_INT >= 31) add(Manifest.permission.BLUETOOTH_CONNECT)
                    }
                    if (permissions.isEmpty()) manager.join(selectedUserId!!, selectedChannelId!!)
                    else permissionLauncher.launch(permissions.toTypedArray())
                },
                enabled = selectedUser != null && selectedChannel != null && !state.loading,
                modifier = Modifier.fillMaxWidth().height(54.dp),
            ) { Text(if (state.loading) "CONNECTING…" else "POWER ON · START") }
            HeadsetPttSettings(state, manager)
            AudioBitrateSettings(state, manager)
            Button(
                onClick = manager::resetDeviceAssignment,
                enabled = !state.loading,
                modifier = Modifier.fillMaxWidth(),
            ) { Text("この端末のユーザーを変更") }
            }
        } else {
            SessionPanel(state, manager)
        }

        state.error?.let { error ->
            Text(error, color = KoeonRed)
            if (error.contains("Microphone permission")) {
                Button(
                    onClick = {
                        context.startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).setData("package:${context.packageName}".toUri()),
                        )
                    },
                ) { Text("App Settings") }
            }
        }
        Diagnostics(state)
    }
}

@Composable
private fun ColumnScope.SessionPanel(state: IntercomUiState, manager: IntercomSessionManager) {
    val joined = state.join ?: return
    val view = LocalView.current
    var inputPressed by remember(joined.sessionId) { mutableStateOf(false) }
    val hapticController = remember(view, joined.sessionId) {
        PttHapticFeedbackController(
            performer = AndroidViewHapticPerformer(view),
            onSnapshot = { snapshot ->
                inputPressed = snapshot.inputPressed
                manager.reportHaptic(snapshot)
            },
        )
    }
    DisposableEffect(hapticController) {
        hapticController.prepare()
        onDispose { hapticController.cancel() }
    }
    val audioReady = state.diagnostics.audioAvailabilityState == AudioAvailabilityState.READY
    val remoteTalking = state.currentSpeaker != null && state.ptt.state != PttState.TRANSMITTING
    val canTransmit = localPttEligible(
        operationallyActive = state.operationalState == OperationalState.ACTIVE,
        canPublish = joined.canPublish,
        connected = state.connectionState == IntercomConnectionState.CONNECTED,
        audioReady = audioReady,
        remoteTalking = remoteTalking,
    )
    val pttSemantic = pttSemanticState(
        canPublish = joined.canPublish,
        connected = state.connectionState == IntercomConnectionState.CONNECTED,
        recovering = state.diagnostics.audioAvailabilityState == AudioAvailabilityState.RECOVERING,
        remoteTalking = remoteTalking,
        pttState = state.ptt.state,
    )
    // Preserve the current gesture until UP, but only READY can start a new one.
    val interactionEnabled = canTransmit && (inputPressed || pttSemantic == PttSemanticState.READY)
    val pttEnabled = interactionEnabled && pttSemantic == PttSemanticState.READY
    val touchDownEligible by rememberUpdatedState(pttEnabled)
    val pttColor = when (pttSemantic) {
        PttSemanticState.READY -> Color(0xFF1DB954)
        PttSemanticState.TALKING -> Color(0xFF16E05D)
        PttSemanticState.BUSY_REMOTE, PttSemanticState.PREPARING -> Color(0xFFFFB020)
        PttSemanticState.ERROR -> Color(0xFFE53935)
        PttSemanticState.RECOVERING, PttSemanticState.OFFLINE, PttSemanticState.RX_ONLY -> Color(0xFF626B67)
    }
    Card(colors = CardDefaults.cardColors(containerColor = KoeonLcd), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Text("CURRENT CHANNEL", color = KoeonGreen, fontSize = 11.sp, fontWeight = FontWeight.Bold)
            val channels = ChannelSwitchPolicy.ordered(state.fixture?.channels.orEmpty())
            val previous = ChannelSwitchPolicy.adjacent(channels, joined.channel.id, -1)
            val next = ChannelSwitchPolicy.adjacent(channels, joined.channel.id, 1)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                Button(onClick = { previous?.let(manager::switchChannel) }, enabled = previous != null && state.operationalState == OperationalState.ACTIVE) { Text("‹") }
                Text(joined.channel.name, color = KoeonGreen, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Button(onClick = { next?.let(manager::switchChannel) }, enabled = next != null && state.operationalState == OperationalState.ACTIVE) { Text("›") }
            }
            Text("${joined.user.name} · ${joined.user.role}")
            Text("${state.operationalState} · ${state.connectionState}", color = if (state.connectionState == IntercomConnectionState.CONNECTED) KoeonSuccess else Color.White)
            Text("Current speaker: ${state.currentSpeaker ?: "None"}")
            if (!audioReady) {
                Text(
                    if (state.diagnostics.audioAvailabilityState == AudioAvailabilityState.RECOVERING) {
                        "AUDIO INTERRUPTED · 音声を復旧しています…"
                    } else {
                        "AUDIO INTERRUPTED · 通話中はPTTを利用できません"
                    },
                    color = Color(0xFFFFB020),
                    fontWeight = FontWeight.Bold,
                )
                if (state.diagnostics.audioAvailabilityState == AudioAvailabilityState.RECOVERY_FAILED) {
                    Button(onClick = manager::retryAudioRecovery, modifier = Modifier.fillMaxWidth()) {
                        Text("音声を再接続")
                    }
                }
            }
            Text("Participants: ${state.participants.joinToString().ifBlank { "None" }}")
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                channels.forEach { channel ->
                    Button(
                        onClick = { manager.switchChannel(channel.id) },
                        enabled = channel.id != joined.channel.id && state.operationalState == OperationalState.ACTIVE,
                    ) {
                        Text(if (channel.id == joined.channel.id) "${channel.name} · ACTIVE" else channel.name)
                    }
                }
            }
        }
    }
    Box(
        modifier = Modifier
            .align(Alignment.CenterHorizontally)
            .size(220.dp)
            .shadow(if (inputPressed) 3.dp else 14.dp, CircleShape, clip = false)
            .graphicsLayer {
                val pressScale = if (inputPressed) 0.97f else 1f
                scaleX = pressScale
                scaleY = pressScale
                translationY = if (inputPressed) 3.dp.toPx() else 0f
            }
            .background(pttColor, CircleShape)
            .semantics {
                contentDescription = "Push to talk, ${pttSemantic.name.replace('_', ' ')}"
                if (!pttEnabled) disabled()
            }
            // PTT owns the accepted pointer stream until physical UP. Initial-pass
            // consumption keeps parent scroll/touch-slop recognizers from cancelling it.
            .pointerInput(joined.sessionId) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    if (!touchDownEligible || !manager.appTouchPttDown(down.id.value)) {
                        return@awaitEachGesture
                    }
                    hapticController.press(eligible = true)
                    down.consume()
                    try {
                        while (true) {
                            val event = awaitPointerEvent(pass = PointerEventPass.Initial)
                            val change = event.changes.firstOrNull { it.id == down.id }
                            if (change == null) {
                                hapticController.cancel()
                                manager.appTouchPttCancel("SYSTEM_CANCEL")
                                break
                            }
                            if (!change.pressed) {
                                change.consume()
                                hapticController.release()
                                manager.appTouchPttUp("PHYSICAL_UP")
                                break
                            }
                            if (change.position != change.previousPosition) {
                                manager.appTouchPttMove(down.id.value)
                            }
                            change.consume()
                        }
                    } catch (cancelled: kotlinx.coroutines.CancellationException) {
                        hapticController.cancel()
                        manager.appTouchPttCancel("SYSTEM_CANCEL")
                        throw cancelled
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            pttSemantic.name.replace('_', ' '),
            color = KoeonBlack,
            fontSize = 22.sp,
            fontWeight = FontWeight.Black,
            textAlign = TextAlign.Center,
        )
    }
    Button(onClick = manager::leaveAsync, enabled = !inputPressed && state.operationalState == OperationalState.ACTIVE, modifier = Modifier.fillMaxWidth()) { Text("POWER OFF", color = KoeonRed) }
    HeadsetPttSettings(state, manager)
    AudioBitrateSettings(state, manager)
    HardwareAndGainSettings(state, manager)
    Button(
        onClick = manager::resetDeviceAssignment,
        enabled = !inputPressed && !state.loading,
        modifier = Modifier.fillMaxWidth(),
    ) { Text("この端末のユーザーを変更") }
}

@Composable
private fun HeadsetPttSettings(state: IntercomUiState, manager: IntercomSessionManager) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text("Headset PTT Button", modifier = Modifier.weight(1f))
        Switch(
            checked = state.diagnostics.headsetPttEnabled,
            onCheckedChange = manager::setHeadsetPttEnabled,
        )
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(
            onClick = { manager.setHeadsetPttMode(HeadsetPttMode.TOGGLE) },
            enabled = state.diagnostics.headsetPttEnabled &&
                state.diagnostics.headsetPttMode != HeadsetPttMode.TOGGLE,
            modifier = Modifier.weight(1f),
        ) { Text("TOGGLE") }
        Button(
            onClick = { manager.setHeadsetPttMode(HeadsetPttMode.MOMENTARY) },
            enabled = state.diagnostics.headsetPttEnabled &&
                state.diagnostics.headsetPttMode != HeadsetPttMode.MOMENTARY,
            modifier = Modifier.weight(1f),
        ) { Text("MOMENTARY") }
    }
}

@Composable
private fun AudioBitrateSettings(state: IntercomUiState, manager: IntercomSessionManager) {
    val diagnostics = state.diagnostics
    Text("音声品質", fontWeight = FontWeight.Bold)
    AudioBitratePreset.entries.forEach { preset ->
        val label = when (preset) {
            AudioBitratePreset.LOW -> "低帯域 12 kbps"
            AudioBitratePreset.STANDARD -> "標準 24 kbps"
            AudioBitratePreset.HIGH -> "高音質 48 kbps"
        }
        Button(
            onClick = { manager.setAudioBitratePreset(preset) },
            enabled = diagnostics.audioBitratePreset != preset,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (diagnostics.audioBitratePreset == preset) "✓ $label" else label)
        }
    }
    Text(
        if (state.joined) {
            "選択値は次のPOWER ONまたはChannel再接続から適用されます"
        } else {
            "次のPOWER ONから送信音声へ適用されます"
        },
        color = Color(0xFF82909A),
        fontSize = 10.sp,
    )
}

@Composable
private fun HardwareAndGainSettings(state: IntercomUiState, manager: IntercomSessionManager) {
    val diagnostics = state.diagnostics
    Text("Hardware Volume PTT · foreground only", fontWeight = FontWeight.Bold)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(
            onClick = { manager.setHardwareVolumePttMode(HardwareVolumePttMode.OFF) },
            enabled = diagnostics.hardwareVolumePttMode != HardwareVolumePttMode.OFF,
            modifier = Modifier.weight(1f),
        ) { Text("OFF") }
        Button(
            onClick = { manager.setHardwareVolumePttMode(HardwareVolumePttMode.TOGGLE) },
            enabled = diagnostics.hardwareVolumePttMode != HardwareVolumePttMode.TOGGLE,
            modifier = Modifier.weight(1f),
        ) { Text("TOGGLE") }
    }
    Text("OUTPUT VOLUME ${diagnostics.outputVolume}/${diagnostics.outputVolumeMax}")
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = { manager.adjustOutputVolume(-1) }, modifier = Modifier.weight(1f)) { Text("−") }
        Button(onClick = { manager.adjustOutputVolume(1) }, modifier = Modifier.weight(1f)) { Text("+") }
    }
    if (BuildConfig.DEBUG) {
        val profileSwitchEnabled = state.joined &&
            state.connectionState == com.dennomuso.koeon.core.livekit.IntercomConnectionState.CONNECTED &&
            diagnostics.audioAvailabilityState == com.dennomuso.koeon.core.audio.AudioAvailabilityState.READY &&
            state.ptt.state == com.dennomuso.koeon.core.ptt.PttState.IDLE
        Text("AUDIO CAPTURE PROFILE", fontWeight = FontWeight.Bold)
        Text("Selected: ${diagnostics.audioCaptureProfile.profileLabel()}", color = KoeonGreen)
        AudioCaptureProfile.entries.forEach { profile ->
            Button(
                onClick = { manager.setAudioCaptureProfile(profile) },
                enabled = profileSwitchEnabled && diagnostics.audioCaptureProfile != profile,
                modifier = Modifier.fillMaxWidth(),
            ) { Text(if (diagnostics.audioCaptureProfile == profile) "✓ ${profile.profileLabel()}" else profile.profileLabel()) }
        }
        Text(
            if (profileSwitchEnabled) "READY / IDLE · profile switching enabled" else "Profile switching locked: requires READY / IDLE",
            color = Color(0xFF82909A),
            fontSize = 10.sp,
        )
    }
    Text("MIC GAIN · ${diagnostics.inputGain.route}", fontWeight = FontWeight.Bold)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        InputGainMode.entries.forEach { mode ->
            Button(
                onClick = { manager.setInputGainMode(mode) },
                enabled = diagnostics.inputGain.mode != mode,
                modifier = Modifier.weight(1f),
            ) { Text(mode.name) }
        }
    }
    Text("Manual ${"%.1f".format(diagnostics.inputGain.manualGainDb)} dB · Effective ${"%.1f".format(diagnostics.inputGain.effectiveGainDb)} dB")
    Slider(
        value = diagnostics.inputGain.manualGainDb,
        onValueChange = manager::setManualInputGain,
        valueRange = -6f..12f,
        steps = 17,
    )
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = manager::startInputCalibration, modifier = Modifier.weight(1f)) { Text("CALIBRATE 3s") }
        Button(onClick = manager::resetInputGainProfile, modifier = Modifier.weight(1f)) { Text("RESET PROFILE") }
    }
    diagnostics.inputGain.recommendedGainDb?.let { Text("Recommended ${"%+.1f".format(it)} dB") }
    Text("TASK003G6B_AUDIO_ROUTE_SELECTION", color = Color(0xFF82909A), fontSize = 10.sp)
}

private fun AudioCaptureProfile.profileLabel(): String = when (this) {
    AudioCaptureProfile.A_CURRENT -> "A CURRENT"
    AudioCaptureProfile.B_GAIN_OFF -> "B AGC OFF / GAIN OFF"
    AudioCaptureProfile.C_KOEON_OWNER -> "C AGC OFF / KOEON AUTO"
    AudioCaptureProfile.D_WEBRTC_OWNER -> "D AGC ON / GAIN OFF"
}

@Composable
private fun Diagnostics(state: IntercomUiState) {
    val context = LocalContext.current
    Card(colors = CardDefaults.cardColors(containerColor = KoeonPanel), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Diagnostics", color = KoeonGreen, fontWeight = FontWeight.Bold)
            Button(onClick = {
                val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("KOEON Field Diagnostic", (context.applicationContext as KoeonApplication).intercomSession.fieldDiagnosticJson()))
            }) { Text("Copy Field Diagnostic JSON") }
            DiagnosticRow("Connection", state.connectionState.name)
            DiagnosticRow("Room", state.join?.roomName ?: "Unavailable")
            DiagnosticRow("User", state.join?.user?.name ?: "Unavailable")
            DiagnosticRow("Channel", state.join?.channel?.name ?: "Unavailable")
            DiagnosticRow("Floor", state.ptt.state.name)
            DiagnosticRow("Lease", state.ptt.leaseId?.let { "Active" } ?: "None")
            DiagnosticRow("Lease TTL", "${state.diagnostics.leaseTtlMs}ms")
            DiagnosticRow("Audio route", state.diagnostics.audioRoute)
            DiagnosticRow("Remote audio tracks", state.diagnostics.remoteAudioTracks.toString())
            DiagnosticRow("Reconnects", state.diagnostics.reconnectCount.toString())
            DiagnosticRow("Uptime", "${state.diagnostics.sessionUptimeSeconds}s")
            DiagnosticRow("Quality", state.diagnostics.connectionQuality)
            DiagnosticRow("Network", state.diagnostics.network)
            DiagnosticRow("Foreground service", state.diagnostics.foregroundService)
            DiagnosticRow("Activity visibility", state.diagnostics.activityVisibility)
            DiagnosticRow("FGS start count", state.diagnostics.foregroundServiceStartCount.toString())
            DiagnosticRow("Notification updates", state.diagnostics.notificationUpdateCount.toString())
            DiagnosticRow("MediaSession active", state.diagnostics.mediaSessionActive.toString())
            DiagnosticRow("Headset PTT enabled", state.diagnostics.headsetPttEnabled.toString())
            DiagnosticRow("Headset PTT mode", state.diagnostics.headsetPttMode.name)
            DiagnosticRow("Last PTT input", state.diagnostics.lastPttInputSource?.name ?: "Unavailable")
            DiagnosticRow("App touch pressed", state.diagnostics.appTouchPressed.toString())
            DiagnosticRow("App touch DOWN/UP/CANCEL", "${state.diagnostics.appTouchDownCount}/${state.diagnostics.appTouchUpCount}/${state.diagnostics.appTouchCancelCount}")
            DiagnosticRow("App touch last DOWN", state.diagnostics.appTouchLastDownAt ?: "Unavailable")
            DiagnosticRow("App touch last UP", state.diagnostics.appTouchLastUpAt ?: "Unavailable")
            DiagnosticRow("App touch last cancel", state.diagnostics.appTouchLastCancelReason ?: "Unavailable")
            DiagnosticRow("Headset latched", state.diagnostics.headsetLatched.toString())
            DiagnosticRow("Headset route present", state.diagnostics.headsetRoutePresent.toString())
            DiagnosticRow("Hardware Volume PTT", state.diagnostics.hardwareVolumePttMode.name)
            DiagnosticRow("Hardware Volume latched", state.diagnostics.hardwareVolumePttLatched.toString())
            DiagnosticRow("Hardware Volume last key", state.diagnostics.hardwareVolumeLastKey ?: "Unavailable")
            DiagnosticRow("Hardware Volume short/long/toggle", "${state.diagnostics.hardwareVolumeShortPressCount}/${state.diagnostics.hardwareVolumeLongPressCount}/${state.diagnostics.hardwareVolumePttToggleCount}")
            DiagnosticRow("Input gain mode", state.diagnostics.inputGain.mode.name)
            DiagnosticRow("Audio capture profile", state.diagnostics.audioCaptureProfile.name)
            DiagnosticRow("Audio bitrate preset", state.diagnostics.audioBitratePreset.name)
            DiagnosticRow("Requested audio bitrate", "${state.diagnostics.requestedAudioBitrateKbps} kbps")
            DiagnosticRow("Effective audio bitrate", state.diagnostics.effectiveAudioBitrateKbps?.let { "$it kbps" } ?: "Unavailable")
            DiagnosticRow("Input gain effective", "${state.diagnostics.inputGain.effectiveGainDb} dB")
            DiagnosticRow("Pre-KOEON RMS/peak", "${state.diagnostics.inputGain.inputRmsDbfs ?: "Unavailable"}/${state.diagnostics.inputGain.inputPeakDbfs ?: "Unavailable"}")
            DiagnosticRow("Post-KOEON RMS/peak", "${state.diagnostics.inputGain.postKoeonRmsDbfs ?: "Unavailable"}/${state.diagnostics.inputGain.postKoeonPeakDbfs ?: "Unavailable"}")
            DiagnosticRow("Limiter hits", state.diagnostics.inputGain.limiterHitCount.toString())
            DiagnosticRow("RX Ready expected", state.diagnostics.rxReadyExpectedCount.toString())
            DiagnosticRow("RX Ready received", state.diagnostics.rxReadyReceivedCount.toString())
            DiagnosticRow("RX Ready late", state.diagnostics.rxReadyLateCount.toString())
            DiagnosticRow("RX Ready protocol", state.diagnostics.rxReadyProtocolVersion.toString())
            DiagnosticRow("RX Ready publish", state.diagnostics.rxReadyPublishResult)
            DiagnosticRow("RX Ready attempted", state.diagnostics.rxReadyPublishAttemptedAt ?: "Unavailable")
            DiagnosticRow("RX Ready published", state.diagnostics.rxReadyPublishedAt ?: "Unavailable")
            DiagnosticRow("RX Ready failure", state.diagnostics.rxReadyPublishFailureClass ?: "None")
            DiagnosticRow("RX Ready START received", state.diagnostics.rxReadyStartReceivedAt ?: "Unavailable")
            DiagnosticRow("RX Ready START armed", state.diagnostics.rxReadyStartArmedAt ?: "Unavailable")
            DiagnosticRow("RX Ready sender identity", state.diagnostics.rxReadySenderIdentityPresent?.toString() ?: "Unavailable")
            DiagnosticRow("RX Ready receiver device ID", state.diagnostics.rxReadyReceiverDeviceIdPresent?.toString() ?: "Unavailable")
            DiagnosticRow("Last media key", state.diagnostics.lastMediaKey ?: "Unavailable")
            DiagnosticRow("Last media action", state.diagnostics.lastMediaKeyAction ?: "Unavailable")
            DiagnosticRow("Connection lost at", state.diagnostics.connectionLostAt ?: "Unavailable")
            DiagnosticRow("Connection restored at", state.diagnostics.connectionRestoredAt ?: "Unavailable")
            DiagnosticRow("Reconnect recovery", state.diagnostics.reconnectRecoveryMs?.let { "${it}ms" } ?: "Unavailable")
            DiagnosticRow("Network changed at", state.diagnostics.networkChangedAt ?: "Unavailable")
            DiagnosticRow("Audio route changed at", state.diagnostics.audioRouteChangedAt ?: "Unavailable")
            DiagnosticRow("Audio route change reason", state.diagnostics.audioRouteChangeReason ?: "Unavailable")
            DiagnosticRow("Audio focus", state.diagnostics.audioFocus)
            DiagnosticRow("audio_availability_state", state.diagnostics.audioAvailabilityState.name)
            DiagnosticRow("interruption_started_at", state.diagnostics.interruptionStartedAt ?: "Unavailable")
            DiagnosticRow("interruption_ended_at", state.diagnostics.interruptionEndedAt ?: "Unavailable")
            DiagnosticRow("interruption_reason", state.diagnostics.interruptionReason ?: "Unavailable")
            DiagnosticRow("mic_track_state", state.diagnostics.microphoneTrackState)
            DiagnosticRow("remote_audio_state", state.diagnostics.remoteAudioState)
            DiagnosticRow("recovery_started_at", state.diagnostics.recoveryStartedAt ?: "Unavailable")
            DiagnosticRow("recovery_completed_at", state.diagnostics.recoveryCompletedAt ?: "Unavailable")
            DiagnosticRow("recovery_ms", state.diagnostics.recoveryMs?.let { "${it}ms" } ?: "Unavailable")
            DiagnosticRow("auto_recovery_result", state.diagnostics.autoRecoveryResult)
            DiagnosticRow("last_recovery_error", state.diagnostics.lastRecoveryError ?: "None")
            DiagnosticRow("Device", state.diagnostics.device)
            DiagnosticRow("RTT", state.diagnostics.rtt)
            DiagnosticRow("Jitter", state.diagnostics.jitter)
            DiagnosticRow("Packet loss", state.diagnostics.packetLoss)
            DiagnosticRow("Last error", state.error ?: "None")
            DiagnosticRow("Start cue", state.ptt.startCueResult)
            DiagnosticRow("End cue", state.ptt.endCueResult)
            DiagnosticRow("Status cue", state.ptt.statusCueResult)
            DiagnosticRow("Control START", state.ptt.controlStartResult)
            DiagnosticRow("Control END", state.ptt.controlEndResult)
            DiagnosticRow("TX Ready expected/received/late", "${state.ptt.rxReadyExpectedCount}/${state.ptt.rxReadyReceivedCount}/${state.ptt.rxReadyLateCount}")
            DiagnosticRow("TX Ready ratio", state.ptt.rxReadyRatioAtMicOn?.let { "%.2f".format(it) } ?: "Unavailable")
            DiagnosticRow("TX Ready wait", state.ptt.timing.readyWaitMs?.let { "${it}ms" } ?: "Unavailable")
            DiagnosticRow("TX Ready timeout", state.ptt.rxReadyTimedOut.toString())
            DiagnosticRow("RX state", state.diagnostics.rx.state.name)
            DiagnosticRow("RX speaker", state.diagnostics.rx.speakerUserId ?: "Unavailable")
            DiagnosticRow("rx_started_at", state.diagnostics.rx.rxStartedAt?.toString() ?: "Unavailable")
            DiagnosticRow("rx_end_signal_at", state.diagnostics.rx.rxEndSignalAt?.toString() ?: "Unavailable")
            DiagnosticRow("rx_drain_started_at", state.diagnostics.rx.rxDrainStartedAt?.toString() ?: "Unavailable")
            DiagnosticRow("rx_drain_completed_at", state.diagnostics.rx.rxDrainCompletedAt?.toString() ?: "Unavailable")
            DiagnosticRow("RX drain", state.diagnostics.rx.rxDrainDurationMs?.let { "${it}ms" } ?: "Unavailable")
            DiagnosticRow("RX end reason", state.diagnostics.rx.rxEndReason ?: "Unavailable")
            DiagnosticRow("Control event type", state.diagnostics.rx.controlEventType ?: "Unavailable")
            DiagnosticRow("RX start cue", state.diagnostics.rx.startCueResult)
            DiagnosticRow("RX end cue", state.diagnostics.rx.endCueResult)
            DiagnosticRow("Control sequence", state.diagnostics.rx.controlSequence?.toString() ?: "Unavailable")
            DiagnosticRow("Control late", state.diagnostics.rx.controlEventLate.toString())
            DiagnosticRow("Fallback / duplicate / stale / preempted", "${state.diagnostics.rx.controlEventFallback} / ${state.diagnostics.rx.duplicateIgnored} / ${state.diagnostics.rx.staleIgnored} / ${state.diagnostics.rx.preempted}")
            DiagnosticRow("Floor latency", state.ptt.timing.floorLatencyMs?.let { "${it}ms" } ?: "Unavailable")
            DiagnosticRow("PTT local enable", state.ptt.timing.localEnableLatencyMs?.let { "${it}ms" } ?: "Unavailable")
            DiagnosticRow("Haptic supported", state.diagnostics.hapticSupported.toString())
            DiagnosticRow("Haptic enabled", state.diagnostics.hapticEnabled.toString())
            DiagnosticRow("Last haptic type", state.diagnostics.lastHapticType ?: "Unavailable")
            DiagnosticRow("Last haptic at", state.diagnostics.lastHapticAt ?: "Unavailable")
            DiagnosticRow("Last haptic result", state.diagnostics.lastHapticResult)
        }
    }
    Spacer(Modifier.height(8.dp))
}

@Composable
private fun DiagnosticRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, color = Color(0xFFB6C1BA))
        Text(value, textAlign = TextAlign.End)
    }
}

package com.dennomuso.koeon

import androidx.compose.ui.semantics.stateDescription
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.requiredHeight
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.ui.graphics.graphicsLayer

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
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
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
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.BoxWithConstraints
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
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
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
import com.dennomuso.koeon.core.audio.MAX_MANUAL_INPUT_GAIN_DB
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

    override fun onDestroy() {
        if (isFinishing) {
            com.dennomuso.koeon.core.audio.AudioLifecycleBreadcrumbs.markCleanExit()
        }
        super.onDestroy()
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

private val LocalConsoleDark = staticCompositionLocalOf { false }
private val KoeonBlack: Color @Composable get() = MaterialTheme.colorScheme.background
private val KoeonPanel: Color @Composable get() = MaterialTheme.colorScheme.surfaceVariant
private val KoeonLcd: Color @Composable get() = if (LocalConsoleDark.current) Color(0xFFC28D3D) else Color(0xFFF0C472)
private val KoeonGreen: Color @Composable get() = MaterialTheme.colorScheme.primary
private val KoeonSuccess = Color(0xFF37B469)
private val KoeonRed = Color(0xFFED5148)

@Composable
private fun KoeonApp(manager: IntercomSessionManager) {
    val state by manager.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val preferences = remember { context.getSharedPreferences("console_appearance", android.content.Context.MODE_PRIVATE) }
    var dark by remember { mutableStateOf(preferences.getBoolean("dark", false)) }
    val colors = if (dark) darkColorScheme(
        background = Color(0xFF1C1E1C), surface = Color(0xFF22271F), surfaceVariant = Color(0xFF30352D),
        onBackground = Color(0xFFE2E4DF), onSurface = Color(0xFFE2E4DF), onSurfaceVariant = Color(0xFFE2E4DF),
        primary = Color(0xFF8CBDEC), onPrimary = Color(0xFF142B3F), error = Color(0xFFFF9B91),
    ) else lightColorScheme(
        background = Color(0xFFF5F5F0), surface = Color(0xFFF8F9F4), surfaceVariant = Color(0xFFE5E8DF),
        onBackground = Color(0xFF343B39), onSurface = Color(0xFF343B39), onSurfaceVariant = Color(0xFF343B39),
        primary = Color(0xFF23699E), onPrimary = Color.White, error = Color(0xFFB32626),
    )
    MaterialTheme(colorScheme = colors) {
        CompositionLocalProvider(LocalConsoleDark provides dark) {
            Surface(color = KoeonBlack, contentColor = MaterialTheme.colorScheme.onBackground, modifier = Modifier.fillMaxSize()) {
                KoeonScreen(state, manager, dark) { value ->
                    dark = value
                    preferences.edit().putBoolean("dark", value).apply()
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KoeonScreen(state: IntercomUiState, manager: IntercomSessionManager, dark: Boolean, onDarkChange: (Boolean) -> Unit) {
    var overlay by remember { mutableStateOf<String?>(null) }
    var powerConfirm by remember { mutableStateOf(false) }
    var resetConfirm by remember { mutableStateOf(false) }
    if (powerConfirm) androidx.compose.material3.AlertDialog(
        onDismissRequest = { powerConfirm = false }, title = { Text("接続を終了しますか？") },
        text = { Text("送受信を終了します。利用登録は保持します。") },
        confirmButton = { Button(onClick = { powerConfirm = false; manager.leaveAsync() }) { Text("POWER OFF") } },
        dismissButton = { Button(onClick = { powerConfirm = false }) { Text("取消") } },
    )
    if (resetConfirm) androidx.compose.material3.AlertDialog(
        onDismissRequest = { resetConfirm = false }, title = { Text("この端末のユーザーを変更しますか？") },
        confirmButton = { Button(onClick = { resetConfirm = false; overlay = null; manager.resetDeviceAssignment() }) { Text("変更") } },
        dismissButton = { Button(onClick = { resetConfirm = false }) { Text("取消") } },
    )
    overlay?.let { title ->
        ConsoleOverlay(title, { overlay = null }) {
            if (title == "Settings") {
                Text("外観", fontWeight = FontWeight.Bold)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(if (dark) "ダーク · ブラック" else "ライト · ホワイト", modifier = Modifier.weight(1f))
                    Switch(checked = dark, onCheckedChange = onDarkChange, modifier = Modifier.semantics { contentDescription = "ダークモード" })
                }
                Text("v${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", fontSize = 12.sp, lineHeight = 15.sp)
                Text("メーターは音声の強さを表示します。端末の音量設定とは別です。「—」は計測なし。", fontSize = 12.sp, lineHeight = 15.sp)
                HeadsetPttSettings(state, manager)
                AudioBitrateSettings(state, manager)
                HardwareAndGainSettings(state, manager)
                Button(onClick = { resetConfirm = true }, enabled = !state.loading && state.ptt.state == PttState.IDLE) { Text("この端末のユーザーを変更") }
            } else Diagnostics(state)
        }
    }
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
        modifier = Modifier.fillMaxSize().safeDrawingPadding()
            .then(if (state.join == null && state.channelSwitchSource == null) Modifier.verticalScroll(rememberScrollState()) else Modifier)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                ConsoleEmblem()
                Text("KOEON", fontSize = 10.sp, lineHeight = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 2.sp, maxLines = 1)
            }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Button(colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = Color.Transparent, disabledContainerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onSurface), onClick = { powerConfirm = true }, enabled = (state.join != null || state.channelSwitchSource != null) && !state.loading, shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(8.dp), modifier = Modifier.size(48.dp).consoleKeyFace().semantics { contentDescription = "POWER" }) { androidx.compose.material3.Icon(Icons.Filled.PowerSettingsNew, contentDescription = null, modifier = Modifier.size(26.dp)) }
            Spacer(Modifier.weight(1f))
            Button(colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = Color.Transparent, disabledContainerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onSurface), onClick = { overlay = "Settings" }, enabled = !state.diagnostics.appTouchPressed, shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(4.dp), modifier = Modifier.size(48.dp).consoleKeyFace().semantics { contentDescription = "Settings" }) { Text("SET", fontSize = 10.sp, lineHeight = 13.sp) }
            Button(colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = Color.Transparent, disabledContainerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onSurface), onClick = { overlay = "Diagnostics" }, enabled = !state.diagnostics.appTouchPressed, shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(4.dp), modifier = Modifier.size(48.dp).consoleKeyFace().semantics { contentDescription = "Diagnostics" }) { Text("DIAG", fontSize = 10.sp, lineHeight = 13.sp) }
        }
        }


        if (state.join == null && state.channelSwitchSource == null) {
            if (state.enrollmentRequired) {
                Text("KOEONを利用登録", color = KoeonGreen, fontSize = 26.sp, lineHeight = 29.sp, fontWeight = FontWeight.Bold)
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
                Text("QRコードを使う場合", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp, lineHeight = 17.sp)
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
            } else if (state.fixture == null) {
                Text(if (state.loading) "登録情報を確認中…" else "登録情報の確認が必要です")
                Button(onClick = { manager.loadFixture() }, enabled = !state.loading,
                    modifier = Modifier.fillMaxWidth().height(54.dp)) { Text("再試行") }
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
            Button(
                onClick = manager::resetDeviceAssignment,
                enabled = !state.loading,
                modifier = Modifier.fillMaxWidth(),
            ) { Text("この端末のユーザーを変更") }
            }
        } else {
            SessionPanel(state, manager)
        }

        state.error?.takeIf { state.join == null && state.channelSwitchSource == null }?.let { error ->
            Text(error, color = MaterialTheme.colorScheme.error)
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
    }
}

@Composable
private fun ColumnScope.SessionPanel(state: IntercomUiState, manager: IntercomSessionManager) {
    val joined = state.join ?: state.channelSwitchSource ?: return
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
    val remoteTalking = state.currentSpeaker != null &&
        state.ptt.state !in setOf(PttState.TRANSMITTING, PttState.RELEASING)
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
        recovering = state.diagnostics.audioAvailabilityState == AudioAvailabilityState.RECOVERING ||
            state.operationalState == OperationalState.RECOVERING_SESSION,
        remoteTalking = remoteTalking,
        pttState = state.ptt.state,
        audioAvailability = state.diagnostics.audioAvailabilityState,
    )
    var digits by remember(joined.channel.id) { mutableStateOf<String?>(null) }
    var entryRejected by remember(joined.channel.id) { mutableStateOf(false) }
    var rejectionSequence by remember(joined.channel.id) { mutableStateOf(0) }
    var flashRed by remember(joined.channel.id) { mutableStateOf(false) }
    fun resetRejection() { entryRejected = false; rejectionSequence = 0; flashRed = false }
    var digitCount by remember { mutableStateOf(1) }
    var pendingChannelId by remember(joined.channel.id) { mutableStateOf<String?>(null) }
    var channelListOpen by remember { mutableStateOf(false) }
    val channels = state.fixture?.channels.orEmpty()
    val channelEnabled = (state.operationalState == OperationalState.ACTIVE || (state.channelSwitchSource != null && state.operationalState == OperationalState.ERROR)) && !state.loading && state.ptt.state == PttState.IDLE && !inputPressed
    val candidate = pendingChannelId?.let { id -> channels.firstOrNull { it.id == id } }
        ?: digits?.takeIf { it.length == digitCount }?.toIntOrNull()?.let { ChannelSwitchPolicy.numbered(channels, it) }
    fun stageChannel(id: String) {
        val channel = channels.firstOrNull { it.id == id } ?: return
        resetRejection()
        pendingChannelId = id
        digits = ChannelSwitchPolicy.number(channel.channelNumber)?.toString().orEmpty()
        digitCount = maxOf(1, digits!!.length)
    }
    LaunchedEffect(digits, pendingChannelId, joined.channel.id, rejectionSequence) {
        if (digits != null) { kotlinx.coroutines.delay(5000); resetRejection(); digits = null; pendingChannelId = null }
    }
    if (channelListOpen) ConsoleOverlay("チャネル一覧", { channelListOpen = false }) {
        Row {
            Button(onClick = { ChannelSwitchPolicy.adjacent(channels, joined.channel.id, -1)?.let(::stageChannel); channelListOpen = false }, enabled = channelEnabled) { Text("前のCH") }
            Button(onClick = { ChannelSwitchPolicy.adjacent(channels, joined.channel.id, 1)?.let(::stageChannel); channelListOpen = false }, enabled = channelEnabled) { Text("次のCH") }
        }
        ChannelSwitchPolicy.ordered(channels).forEach { channel ->
            Button(onClick = { stageChannel(channel.id); channelListOpen = false }, enabled = channelEnabled && channel.id != joined.channel.id, modifier = Modifier.fillMaxWidth()) { Text(channel.name) }
        }
    }
    // Preserve the current gesture until UP, but only READY can start a new one.
    val interactionEnabled = canTransmit && (inputPressed || pttSemantic == PttSemanticState.READY)
    val pttEnabled = interactionEnabled && pttSemantic == PttSemanticState.READY && digits == null
    val touchDownEligible by rememberUpdatedState(pttEnabled)
    val currentChoice = channels.firstOrNull { it.id == joined.channel.id }
    val currentNumber = ChannelSwitchPolicy.number(if (currentChoice != null) currentChoice.channelNumber else joined.channel.channelNumber)
    val keyDigits = ChannelSwitchPolicy.digits(currentNumber, digits, digitCount)
    val twoDigitActive = if (digits != null) digitCount == 2 else (currentNumber ?: 0) >= 10
    val warningActive = com.dennomuso.koeon.core.ptt.consoleWarningActive(pttSemantic, state.diagnostics.audioAvailabilityState)
    val pttColor = if (warningActive) KoeonRed else when (pttSemantic) {
        PttSemanticState.READY -> Color.Gray.copy(alpha = .4f)
        PttSemanticState.TALKING -> Color(0xFF16E05D)
        PttSemanticState.BUSY_REMOTE, PttSemanticState.PREPARING -> Color(0xFFFFB020)
        PttSemanticState.ERROR -> Color(0xFFE53935)
        PttSemanticState.INTERRUPTED -> KoeonRed
        PttSemanticState.RECOVERING -> Color(0xFFFFB020)
        PttSemanticState.OFFLINE, PttSemanticState.RX_ONLY -> Color.Gray.copy(alpha = .4f)
    }
    var membersOpen by remember { mutableStateOf(false) }
    if (membersOpen) ConsoleOverlay("参加メンバー", { membersOpen = false }) {
        state.participants.forEach { Text(it, fontSize = 22.sp, lineHeight = 25.sp) }
    }
    val reduceMotion = android.provider.Settings.Global.getFloat(LocalContext.current.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    LaunchedEffect(rejectionSequence) {
        if (rejectionSequence > 0) {
            if (reduceMotion) { flashRed = true; kotlinx.coroutines.delay(1200); flashRed = false }
            else repeat(3) { flashRed = true; kotlinx.coroutines.delay(200); flashRed = false; kotlinx.coroutines.delay(200) }
        }
    }

    var cursorOn by remember { mutableStateOf(true) }
    LaunchedEffect(digits, reduceMotion) {
        cursorOn = true
        if (digits != null && !reduceMotion) while (true) { kotlinx.coroutines.delay(500); cursorOn = !cursorOn }
    }
    Card(colors = CardDefaults.cardColors(containerColor = KoeonLcd, contentColor = Color(0xFF382B10)), shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp), modifier = Modifier.fillMaxWidth().requiredHeight(202.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp)).border(5.dp, if (LocalConsoleDark.current) Color(0xFF10140E) else Color(0xFFAEB5A6), androidx.compose.foundation.shape.RoundedCornerShape(8.dp))) {
        Column(Modifier.fillMaxSize().padding(12.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(2.dp)), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (digits != null) {
                Text("CHANNEL EDIT / 変更元 → 変更先", fontSize = 11.sp, lineHeight = 14.sp)
                Text("FROM  ${joined.channel.name}", fontSize = 20.sp, lineHeight = 23.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, softWrap = false)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("TO CH", fontSize = 24.sp, lineHeight = 27.sp)
                    repeat(digitCount) { index ->
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(digits!!.getOrNull(index)?.toString() ?: "_", fontSize = 30.sp, lineHeight = 33.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                            Box(Modifier.width(20.dp).height(3.dp).background(if (pendingChannelId == null && index == digits!!.length && cursorOn) Color(0xFF382B10) else Color.Transparent))
                        }
                    }
                    Text(if (entryRejected) "未割当" else if (digits!!.length < digitCount && pendingChannelId == null) "入力中" else "確定待ち", fontSize = 14.sp, lineHeight = 17.sp)
                }
                Text(if (entryRejected) "このCHは未割り当てです" else candidate?.name ?: "番号を選択して確定してください", fontSize = 20.sp, lineHeight = 23.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, softWrap = false)
            } else {
                Text(if (state.channelSwitchSource != null && state.operationalState != OperationalState.ERROR) "CH CHANGE / 接続切替中…" else "${currentNumber?.let { "CH$it" } ?: "CH —"} / ${state.connectionState} · ${pttSemantic.name}", fontSize = 11.sp, lineHeight = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, softWrap = false)
                Text(joined.channel.name, fontSize = 24.sp, lineHeight = 27.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, softWrap = false, modifier = Modifier.clickable(enabled = channelEnabled) { channelListOpen = true })
                Text("SPEAKER / 発話者", fontSize = 10.sp, lineHeight = 13.sp)
                Text(if (pttSemantic == PttSemanticState.TALKING) "自分" else state.currentSpeaker ?: "—", fontSize = 22.sp, lineHeight = 25.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, softWrap = false)
                Text("MEMBERS / 参加者 ${state.participants.size}", fontSize = 10.sp, lineHeight = 13.sp)
                Text(state.participants.joinToString(" · ").ifBlank { "—" }, fontSize = 22.sp, lineHeight = 25.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, softWrap = false, modifier = Modifier.clickable { membersOpen = true })
            }
            Spacer(Modifier.weight(1f))
            Row(Modifier.fillMaxWidth().height(16.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(if (state.error != null) state.error!! else "AUDIO: ${state.diagnostics.audioRoute}", modifier = Modifier.weight(1f), fontSize = 9.sp, lineHeight = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, softWrap = false)
                Text("v${BuildConfig.VERSION_NAME}", fontSize = 9.sp, lineHeight = 12.sp, maxLines = 1, softWrap = false)
            }
        }
    }
    if (!audioReady) {
        if (state.diagnostics.audioAvailabilityState in setOf(AudioAvailabilityState.INTERRUPTED, AudioAvailabilityState.RECOVERY_FAILED)) {
            Button(onClick = manager::retryAudioRecovery) { Text("音声を再接続") }
        }
    }
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(18.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            ConsoleLamp("PTT", pttColor)
            ConsoleLamp("RX", if (state.diagnostics.rx.state in setOf(com.dennomuso.koeon.core.ptt.RxState.RX_ACTIVE, com.dennomuso.koeon.core.ptt.RxState.RX_DRAINING) || (state.diagnostics.rx.state != com.dennomuso.koeon.core.ptt.RxState.RX_IDLE && state.receiveLevelDbfs != null)) Color(0xFF328BDF) else Color.Gray.copy(alpha = .4f))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            ConsoleMeter("TX IN", if (pttSemantic == PttSemanticState.TALKING) state.transmitInputLevelDbfs else null, KoeonSuccess)
            ConsoleMeter("RX", if (state.connectionState == IntercomConnectionState.CONNECTED) state.receiveLevelDbfs else null, Color(0xFF328BDF))
        }
    }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text("CHANNEL SELECT", fontSize = 11.sp, lineHeight = 14.sp, letterSpacing = 1.sp)
        Spacer(Modifier.weight(1f))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.semantics { contentDescription = "10の位：緑、1の位：青" }) {
            Box(Modifier.size(6.dp).background(Color(0xFF37B469), CircleShape))
            Text("TENS", fontSize = 9.sp, lineHeight = 12.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.width(1.dp))
            Box(Modifier.size(6.dp).background(Color(0xFF328BDF), CircleShape))
            Text("ONES", fontSize = 9.sp, lineHeight = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
    repeat(2) { row ->
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            repeat(5) { column ->
                val number = row * 5 + column
                Button(
                    onClick = {
                        resetRejection()
                        pendingChannelId = null
                        if (digits != null && digitCount == 2) { if (digits!!.length < 2) digits += number.toString() }
                        else { digitCount = 1; digits = number.toString() }
                    },
                    enabled = channelEnabled,
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(4.dp),
                    colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                        containerColor = Color.Transparent, disabledContainerColor = Color.Transparent,
                        contentColor = if (LocalConsoleDark.current) Color(0xFFE6E6E6) else Color(0xFF333333),
                        disabledContentColor = Color(0xFF888888)
                    ),
                    modifier = Modifier.weight(1f).height(44.dp).consoleKeyFace().channelLED(keyDigits.ones == number, keyDigits.tens == number, flashRed).semantics { stateDescription = if (keyDigits.ones == number && keyDigits.tens == number) "1の位・10の位" else if (keyDigits.ones == number) "1の位" else if (keyDigits.tens == number) "10の位" else "消灯" },
                ) {
                    Text(number.toString(), fontSize = 20.sp, lineHeight = 23.sp, fontWeight = FontWeight.Bold, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                }
            }
        }
    }
    Row(Modifier.fillMaxWidth().height(48.dp), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
        ConsoleActionKey("2桁", channelEnabled, twoDigitActive) { resetRejection(); pendingChannelId = null; digitCount = 2; digits = "" }
        ConsoleActionKey("確定", channelEnabled && ChannelSwitchPolicy.canConfirm(digits, digitCount, pendingChannelId != null && candidate != null)) {
            if (candidate != null) { manager.switchChannel(candidate.id); resetRejection(); digits = null; pendingChannelId = null }
            else { entryRejected = true; rejectionSequence += 1; view.announceForAccessibility("未割り当てのCHです") }
        }
        ConsoleActionKey("取消", digits != null) { resetRejection(); digits = null; pendingChannelId = null }
    }
    BoxWithConstraints(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
    val diameter = minOf(maxHeight, maxWidth, 220.dp)
    Box(
        modifier = Modifier
            .size(diameter)
            .shadow(if (inputPressed) 3.dp else 14.dp, CircleShape, clip = false)
            .graphicsLayer {
                val pressScale = if (inputPressed) 0.97f else 1f
                scaleX = pressScale
                scaleY = pressScale
                translationY = if (inputPressed) 3.dp.toPx() else 0f
            }
            .consoleKeyFace(CircleShape)
            .background(androidx.compose.ui.graphics.Brush.radialGradient(0f to Color.Transparent, .48f to Color.Transparent, .86f to pttColor.copy(alpha = .24f), 1f to pttColor.copy(alpha = .6f)), CircleShape)
            .border(5.dp, pttColor.copy(alpha = .8f), CircleShape)
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
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("PTT", color = MaterialTheme.colorScheme.onSurface, fontSize = 42.sp, lineHeight = 45.sp, fontWeight = FontWeight.Bold, letterSpacing = 3.sp)
            Text(pttSemantic.name.replace('_', ' '), color = MaterialTheme.colorScheme.onSurface, fontSize = 14.sp, lineHeight = 17.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        }
    }

    }
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
        "LiveKitの送信音質と通信量を変更します。速度制限中は低音質（12kbps）を選んでください。",
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontSize = 10.sp, lineHeight = 13.sp,
    )
    Text(
        "選択値は保存され、次回接続時に適用されます。",
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontSize = 10.sp, lineHeight = 13.sp,
    )
}

@Composable
private fun HardwareAndGainSettings(state: IntercomUiState, manager: IntercomSessionManager) {
    val diagnostics = state.diagnostics
    val context = LocalContext.current
    var showBackgroundConsent by remember { mutableStateOf(false) }
    Text("Hardware Volume PTT · 長押し", fontWeight = FontWeight.Bold)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("背景で音量PTT（試作）", modifier = Modifier.weight(1f))
        Switch(checked = diagnostics.backgroundVolumePttEnabled,
            onCheckedChange = { enabled ->
                if (enabled) showBackgroundConsent = true else manager.setBackgroundVolumePttEnabled(false)
            }, modifier = Modifier.semantics { contentDescription = "Background Volume PTT" })
    }
    Text("約0.6秒以上の長押しで開始・次の長押しで停止。短押しは音量調整。背景設定OFFでは前面のみ。背景利用にはTOGGLEとOSサービスの有効化が必要です。消灯時の動作は機種によって異なります。", fontSize = 11.sp, lineHeight = 14.sp)
    if (diagnostics.backgroundVolumePttEnabled) {
        Text(if (diagnostics.backgroundVolumeServiceConnected) "OSサービス: 接続済み" else "OSサービス: 未接続")
        Button(onClick = { context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }) { Text("背景PTTのOS設定") }
    }
    if (showBackgroundConsent) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showBackgroundConsent = false },
            title = { Text("背景の音量ボタンで送信") },
            text = { Text("Accessibilityサービスで音量ボタンの押下・解放を検出します。参加中は約0.6秒以上の長押しで送信開始・停止を切り替えます。短押しは解放時に音量を1段階調整します。画面内容は取得せず、音量以外のキーを記録・送信しません。背景設定とOSサービスをOFFにすると無効になります。ロック中も誤って押すと送信する場合があります。") },
            confirmButton = { Button(onClick = { manager.setBackgroundVolumePttEnabled(true); showBackgroundConsent = false }) { Text("同意して有効化") } },
            dismissButton = { Button(onClick = { showBackgroundConsent = false }) { Text("キャンセル") } },
        )
    }
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
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 10.sp, lineHeight = 13.sp,
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
        valueRange = -6f..MAX_MANUAL_INPUT_GAIN_DB,
        steps = 29,
    )
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = manager::startInputCalibration, modifier = Modifier.weight(1f)) { Text("CALIBRATE 3s") }
        Button(onClick = manager::resetInputGainProfile, modifier = Modifier.weight(1f)) { Text("RESET PROFILE") }
    }
    diagnostics.inputGain.recommendedGainDb?.let { Text("Recommended ${"%+.1f".format(it)} dB") }
    Text("TASK003G6B_AUDIO_ROUTE_SELECTION", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 10.sp, lineHeight = 13.sp)
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
    val journalScope = rememberCoroutineScope()
    var journalBusy by remember { mutableStateOf(false) }
    var journalStatus by remember { mutableStateOf("") }
    val saveJournal = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri == null) journalBusy = false
        else journalScope.launch {
            try {
                val journal = (context.applicationContext as KoeonApplication).intercomSession.fieldJournal
                journal.record("EXPORT")
                val file = journal.export()
                withContext(Dispatchers.IO) {
                    requireNotNull(context.contentResolver.openOutputStream(uri)).use { out -> file.inputStream().use { it.copyTo(out) } }
                }
                journalStatus = "Saved (up to 24 hours)"
            } catch (_: Exception) { journalStatus = "Export failed; retry when storage is available" }
            finally { journalBusy = false }
        }
    }
    Card(colors = CardDefaults.cardColors(containerColor = KoeonPanel), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Diagnostics", color = KoeonGreen, fontWeight = FontWeight.Bold)
            DiagnosticRow("RX meter input", state.receiveLevelFormat)
            Button(onClick = {
                val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("KOEON Field Diagnostic", (context.applicationContext as KoeonApplication).intercomSession.fieldDiagnosticJson()))
            }) { Text("Copy Field Diagnostic JSON") }
            Button(enabled = !journalBusy, onClick = {
                journalBusy = true
                saveJournal.launch("KOEON-field-journal-${System.currentTimeMillis()}.json")
            }) { Text("Export 24-hour Field Journal") }
            if (journalStatus.isNotEmpty()) Text(journalStatus)
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
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, textAlign = TextAlign.End)
    }
}

@Composable
private fun ConsoleOverlay(title: String, close: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    androidx.compose.ui.window.Dialog(onDismissRequest = close, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(color = MaterialTheme.colorScheme.surface, contentColor = MaterialTheme.colorScheme.onSurface, shape = androidx.compose.foundation.shape.RoundedCornerShape(18.dp), modifier = Modifier.fillMaxWidth().padding(12.dp)) {
            Column(Modifier.padding(16.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(title, fontSize = 22.sp, lineHeight = 25.sp, modifier = Modifier.weight(1f))
                    Button(onClick = close) { Text("閉じる") }
                }
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
            }
        }
    }
}

@Composable
private fun ConsoleLamp(label: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(12.dp).background(color, CircleShape))
        Text(label, fontSize = 12.sp, lineHeight = 15.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun ConsoleMeter(label: String, db: Float?, color: Color) {
    val level = db?.takeIf { it.isFinite() }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.semantics { contentDescription = "$label: ${level?.let { "$it dBFS" } ?: "未取得"}" }) {
        Text(label, fontSize = 10.sp, lineHeight = 13.sp, modifier = Modifier.width(35.dp))
        repeat(12) { index ->
            val active = level != null && index < ((level + 60) / 5).coerceIn(0f, 12f)
            Box(Modifier.weight(1f).height(8.dp).background(if (active) { if (index >= 11) KoeonRed else color } else MaterialTheme.colorScheme.onSurface.copy(alpha = .18f)))
        }
        Text(level?.let { "%.0f".format(it) } ?: "—", fontSize = 10.sp, lineHeight = 13.sp, modifier = Modifier.width(26.dp))
    }
}

private fun Modifier.channelLED(blue: Boolean, green: Boolean, red: Boolean = false): Modifier {
    if (!blue && !green && !red) return this
    val left = if (red) KoeonRed else if (green) Color(0xFF37B469) else Color(0xFF328BDF)
    val right = if (red) KoeonRed else if (blue) Color(0xFF328BDF) else Color(0xFF37B469)
    val brush = androidx.compose.ui.graphics.Brush.horizontalGradient(
        0f to left, .499f to left, .5f to right, 1f to right
    )
    val shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp)
    return clip(shape).drawWithContent {
        // Nested translucent bands diffuse the embedded edge LED toward the centre.
        for (width in 2..30) {
            drawRoundRect(brush, cornerRadius = androidx.compose.ui.geometry.CornerRadius(7.dp.toPx()),
                style = androidx.compose.ui.graphics.drawscope.Stroke(width.dp.toPx()), alpha = if (width < 4) .22f else .025f)
        }
        drawContent()
    }
}

@Composable
private fun ConsoleEmblem() {
    val shape = androidx.compose.foundation.shape.RoundedCornerShape(5.dp)
    val gold = androidx.compose.ui.graphics.Brush.linearGradient(
        0f to Color(0xFFFFF1B8), .35f to Color(0xFFB48430),
        .46f to Color(0xFFFFE6A0), .52f to Color(0xFFB88530),
        .82f to Color(0xFFD9B65C), 1f to Color(0xFFFFF0AA)
    )
    Box(Modifier.size(34.dp, 30.dp).shadow(1.dp, shape).background(gold, shape)
        .border(.7.dp, Color(0xFF8F611C), shape), contentAlignment = Alignment.Center) {
        for (highlight in listOf(true, false)) {
            androidx.compose.foundation.Image(
                painter = androidx.compose.ui.res.painterResource(R.drawable.ic_launcher_monochrome),
                contentDescription = null,
                colorFilter = androidx.compose.ui.graphics.ColorFilter.tint(if (highlight) Color(0xFFFFF2BA) else Color(0xFF593B12)),
                modifier = Modifier.requiredSize(42.dp).graphicsLayer {
                    translationX = -1.1.dp.toPx()
                    translationY = if (highlight) .7.dp.toPx() else 0f
                }
            )
        }
    }
}

@Composable
private fun ConsoleActionKey(label: String, enabled: Boolean, green: Boolean = false, onClick: () -> Unit) {
    val dark = LocalConsoleDark.current
    val shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp)
    Button(
        onClick = onClick, enabled = enabled, shape = shape,
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp),
        colors = androidx.compose.material3.ButtonDefaults.buttonColors(
            containerColor = Color.Transparent, disabledContainerColor = Color.Transparent,
            contentColor = if (dark) Color(0xFFE6E6E6) else Color(0xFF333333),
            disabledContentColor = Color(0xFF888888)
        ),
        modifier = Modifier.width(52.dp).height(44.dp).consoleKeyFace().channelLED(false, green)
    ) { Text(label, fontSize = 17.sp, lineHeight = 20.sp) }
}

@Composable
private fun Modifier.consoleKeyFace(shape: androidx.compose.ui.graphics.Shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp)): Modifier {
    val face = androidx.compose.ui.graphics.Brush.verticalGradient(
        if (LocalConsoleDark.current) listOf(Color(0x667D8981), Color(0x40303733), Color(0x70242A27))
        else listOf(Color(0x80FFFFFF), Color(0x40CBD2CE), Color(0x66DEE3DF))
    )
    return shadow(3.dp, shape, clip = false).background(face, shape)
        .border(1.dp, androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Color.White.copy(alpha = .75f), Color.White.copy(alpha = .08f), Color.Black.copy(alpha = .22f))), shape)
}

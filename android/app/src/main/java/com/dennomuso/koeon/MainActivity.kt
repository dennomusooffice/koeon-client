package com.dennomuso.koeon

import androidx.compose.ui.semantics.stateDescription
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.drawOutline
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
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
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
private val LocalKeyDark = staticCompositionLocalOf { false }
private val LocalLcdBlue = staticCompositionLocalOf { false }
private val ConsoleKeyInk: Color @Composable get() = if (LocalKeyDark.current) Color(0xFFF0F0ED) else Color(0xFF292D2B)
private val ConsoleLcdInk: Color @Composable get() = if (LocalLcdBlue.current) Color(0xFFF7FAFF) else Color(0xFF382B10)
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
    var bodyColor by remember { mutableStateOf(preferences.getString("body_color", null) ?: if (preferences.getBoolean("dark", false)) "black" else "white") }
    var keyColor by remember { mutableStateOf(preferences.getString("key_color", null) ?: if (bodyColor == "white") "white" else "black") }
    var lcdColor by remember { mutableStateOf(preferences.getString("lcd_color", "amber") ?: "amber") }
    val dark = bodyColor != "white"
    val body = when (bodyColor) { "burgundy" -> Color(0xFF522431); "navy" -> Color(0xFF172C46); "black" -> Color(0xFF1C1F1D); else -> Color(0xFFF4F4EF) }
    val colors = if (dark) darkColorScheme(
        background = body, surface = body, surfaceVariant = body.copy(alpha = .8f),
        onBackground = Color(0xFFE2E4DF), onSurface = Color(0xFFE2E4DF), onSurfaceVariant = Color(0xFFE2E4DF),
        primary = Color(0xFF8CBDEC), onPrimary = Color(0xFF142B3F), error = Color(0xFFFF9B91),
    ) else lightColorScheme(
        background = body, surface = body, surfaceVariant = Color(0xFFE5E8DF),
        onBackground = Color(0xFF343B39), onSurface = Color(0xFF343B39), onSurfaceVariant = Color(0xFF343B39),
        primary = Color(0xFF23699E), onPrimary = Color.White, error = Color(0xFFB32626),
    )
    MaterialTheme(colorScheme = colors) {
        CompositionLocalProvider(LocalConsoleDark provides dark, LocalKeyDark provides (keyColor == "black"), LocalLcdBlue provides (lcdColor == "blue")) {
            Surface(color = KoeonBlack, contentColor = MaterialTheme.colorScheme.onBackground, modifier = Modifier.fillMaxSize()) {
                KoeonScreen(state, manager, bodyColor, keyColor, lcdColor,
                    { bodyColor = it; preferences.edit().putString("body_color", it).apply() },
                    { keyColor = it; preferences.edit().putString("key_color", it).apply() },
                    { lcdColor = it; preferences.edit().putString("lcd_color", it).apply() })
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KoeonScreen(state: IntercomUiState, manager: IntercomSessionManager, bodyColor: String, keyColor: String, lcdColor: String, onBodyChange: (String) -> Unit, onKeyChange: (String) -> Unit, onLcdChange: (String) -> Unit) {
    var overlay by remember { mutableStateOf<String?>(null) }
    var lcdMode by remember { mutableStateOf<String?>(null) }
    var lcdEpoch by remember { mutableStateOf(0) }
    var resetConfirm by remember { mutableStateOf(false) }
    LaunchedEffect(state.join, state.channelSwitchSource) {
        if (state.join == null && state.channelSwitchSource == null) lcdMode = null
    }
    if (resetConfirm) androidx.compose.material3.AlertDialog(
        onDismissRequest = { resetConfirm = false }, title = { Text("この端末のユーザーを変更しますか？") },
        confirmButton = { Button(onClick = { resetConfirm = false; overlay = null; manager.resetDeviceAssignment() }) { Text("変更") } },
        dismissButton = { Button(onClick = { resetConfirm = false }) { Text("取消") } },
    )
    overlay?.let { title ->
        ConsoleOverlay(title, { overlay = null }) {
            if (title == "Settings") {
                Text("外観", fontWeight = FontWeight.Bold)
                ConsoleAppearancePicker("本体色", bodyColor, listOf("white" to "ホワイト", "black" to "ブラック", "burgundy" to "バーガンディー", "navy" to "ネイビー"), onBodyChange)
                ConsoleAppearancePicker("ボタン色", keyColor, listOf("white" to "ホワイト系", "black" to "ブラック系"), onKeyChange)
                ConsoleAppearancePicker("LCD", lcdColor, listOf("amber" to "アンバー", "blue" to "ディープブルー"), onLcdChange)
                if (state.diagnostics.audioAvailabilityState in setOf(AudioAvailabilityState.INTERRUPTED, AudioAvailabilityState.RECOVERY_FAILED)) {
                    Button(onClick = manager::retryAudioRecovery) { Text("音声を再接続") }
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
            Button(colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = Color.Transparent, disabledContainerColor = Color.Transparent, contentColor = ConsoleKeyInk), onClick = { lcdEpoch += 1; lcdMode = "power" }, enabled = (state.join != null || state.channelSwitchSource != null) && !state.loading && state.ptt.state == PttState.IDLE, shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(8.dp), modifier = Modifier.size(48.dp).consoleKeyFace().semantics { contentDescription = "POWER" }) { androidx.compose.material3.Icon(Icons.Filled.PowerSettingsNew, contentDescription = null, modifier = Modifier.size(26.dp)) }
            Spacer(Modifier.weight(1f))
            Button(colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = Color.Transparent, disabledContainerColor = Color.Transparent, contentColor = ConsoleKeyInk), onClick = { if (state.join != null || state.channelSwitchSource != null) { lcdEpoch += 1; lcdMode = "settings" } else overlay = "Settings" }, enabled = !state.diagnostics.appTouchPressed && state.ptt.state == PttState.IDLE, shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(4.dp), modifier = Modifier.size(48.dp).consoleKeyFace().semantics { contentDescription = "Settings" }) { Text("SET", fontSize = 10.sp, lineHeight = 13.sp) }
            Button(colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = Color.Transparent, disabledContainerColor = Color.Transparent, contentColor = ConsoleKeyInk), onClick = { overlay = "Diagnostics" }, enabled = !state.diagnostics.appTouchPressed, shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(4.dp), modifier = Modifier.size(48.dp).consoleKeyFace().semantics { contentDescription = "Diagnostics" }) { Text("DIAG", fontSize = 10.sp, lineHeight = 13.sp) }
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
            SessionPanel(state, manager, lcdMode, lcdEpoch, { lcdMode = it }, bodyColor, keyColor, lcdColor, onBodyChange, onKeyChange, onLcdChange)
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
private fun ColumnScope.SessionPanel(state: IntercomUiState, manager: IntercomSessionManager, lcdMode: String?, lcdEpoch: Int, onLcdModeChange: (String?) -> Unit, bodyColor: String, keyColor: String, lcdColor: String, onBodyChange: (String) -> Unit, onKeyChange: (String) -> Unit, onLcdChange: (String) -> Unit) {
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
    val channelEnabled = lcdMode == null && (state.operationalState == OperationalState.ACTIVE || (state.channelSwitchSource != null && state.operationalState == OperationalState.ERROR)) && !state.loading && state.ptt.state == PttState.IDLE && !inputPressed
    val candidate = pendingChannelId?.let { id -> channels.firstOrNull { it.id == id } }
        ?: digits?.takeIf { it.length == digitCount }?.toIntOrNull()?.let { ChannelSwitchPolicy.numbered(channels, it) }
    fun stageChannel(id: String) {
        val channel = channels.firstOrNull { it.id == id } ?: return
        resetRejection()
        pendingChannelId = id
        digits = ChannelSwitchPolicy.number(channel.channelNumber)?.toString().orEmpty()
        digitCount = maxOf(1, digits!!.length)
    }
    LaunchedEffect(lcdMode, lcdEpoch) {
        if (lcdMode != null) { resetRejection(); digits = null; pendingChannelId = null }
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
    var settingIndex by remember(lcdMode, lcdEpoch) { mutableStateOf(0) }
    var menuLevel by remember(lcdMode, lcdEpoch) { mutableStateOf(0) }
    var choiceIndex by remember(lcdMode, lcdEpoch) { mutableStateOf(0) }
    var confirmYes by remember(lcdMode, lcdEpoch) { mutableStateOf(false) }
    var showBackgroundConsent by remember { mutableStateOf(false) }
    val menuContext = LocalContext.current
    val menuEntries = buildList {
        add(LCDMenuEntry("本体色", bodyColor, listOf("ホワイト", "ブラック", "バーガンディー", "ネイビー"), listOf("white", "black", "burgundy", "navy").indexOf(bodyColor).coerceAtLeast(0), onChoice = { onBodyChange(listOf("white", "black", "burgundy", "navy")[it]) }))
        add(LCDMenuEntry("ボタン色", if (keyColor == "black") "ブラック系" else "ホワイト系", listOf("ホワイト系", "ブラック系"), if (keyColor == "black") 1 else 0, onChoice = { onKeyChange(listOf("white", "black")[it]) }))
        add(LCDMenuEntry("LCD", if (lcdColor == "blue") "ディープブルー" else "アンバー", listOf("アンバー", "ディープブルー"), if (lcdColor == "blue") 1 else 0, onChoice = { onLcdChange(listOf("amber", "blue")[it]) }))
        add(LCDMenuEntry("ヘッドセットPTT", if (state.diagnostics.headsetPttEnabled) "ON" else "OFF", listOf("OFF", "ON"), if (state.diagnostics.headsetPttEnabled) 1 else 0, onChoice = { manager.setHeadsetPttEnabled(it == 1) }))
        add(LCDMenuEntry("ヘッドセット動作", if (state.diagnostics.headsetPttEnabled) state.diagnostics.headsetPttMode.name else "先にPTTをON", if (state.diagnostics.headsetPttEnabled) listOf("TOGGLE", "MOMENTARY") else emptyList(), if (state.diagnostics.headsetPttMode == HeadsetPttMode.TOGGLE) 0 else 1, onChoice = { manager.setHeadsetPttMode(if (it == 0) HeadsetPttMode.TOGGLE else HeadsetPttMode.MOMENTARY) }))
        add(LCDMenuEntry("送信音声", state.diagnostics.audioBitratePreset.name, AudioBitratePreset.entries.map { it.name }, AudioBitratePreset.entries.indexOf(state.diagnostics.audioBitratePreset), onChoice = { manager.setAudioBitratePreset(AudioBitratePreset.entries[it]) }))
        add(LCDMenuEntry("音量ボタンPTT", state.diagnostics.hardwareVolumePttMode.name, listOf("OFF", "TOGGLE"), if (state.diagnostics.hardwareVolumePttMode == HardwareVolumePttMode.OFF) 0 else 1, onChoice = { manager.setHardwareVolumePttMode(if (it == 0) HardwareVolumePttMode.OFF else HardwareVolumePttMode.TOGGLE) }))
        add(LCDMenuEntry("背景音量PTT", if (state.diagnostics.backgroundVolumePttEnabled) "ON" else "OFF", listOf("OFF", "ON"), if (state.diagnostics.backgroundVolumePttEnabled) 1 else 0, onChoice = { if (it == 1) showBackgroundConsent = true else manager.setBackgroundVolumePttEnabled(false) }))
        if (state.diagnostics.backgroundVolumePttEnabled) add(LCDMenuEntry("背景PTTのOS設定", "決定でOS設定へ", action = { menuContext.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }))
        add(LCDMenuEntry("受信音量", "${state.diagnostics.outputVolume}/${state.diagnostics.outputVolumeMax}", listOf("− 1段階", "+ 1段階"), 0, onChoice = { manager.adjustOutputVolume(if (it == 0) -1 else 1) }))
        add(LCDMenuEntry("マイクゲイン", state.diagnostics.inputGain.mode.name, InputGainMode.entries.map { it.name }, InputGainMode.entries.indexOf(state.diagnostics.inputGain.mode), onChoice = { manager.setInputGainMode(InputGainMode.entries[it]) }))
        add(LCDMenuEntry("手動ゲイン dB", "${state.diagnostics.inputGain.manualGainDb}", (-6..24).map { it.toString() }, (state.diagnostics.inputGain.manualGainDb.toInt() + 6).coerceIn(0, 30), onChoice = { manager.setManualInputGain((it - 6).toFloat()) }))
        add(LCDMenuEntry("ゲイン測定", "3秒間測定", action = manager::startInputCalibration))
        add(LCDMenuEntry("ゲイン履歴消去", "YESで消去", action = manager::resetInputGainProfile, confirm = true))
        if (BuildConfig.DEBUG) {
            val profileEnabled = state.joined && state.connectionState == IntercomConnectionState.CONNECTED && state.diagnostics.audioAvailabilityState == AudioAvailabilityState.READY && state.ptt.state == PttState.IDLE
            add(LCDMenuEntry("録音プロファイル", if (profileEnabled) state.diagnostics.audioCaptureProfile.profileLabel() else "READY/IDLE時のみ", if (profileEnabled) AudioCaptureProfile.entries.map { it.profileLabel() } else emptyList(), AudioCaptureProfile.entries.indexOf(state.diagnostics.audioCaptureProfile), onChoice = { manager.setAudioCaptureProfile(AudioCaptureProfile.entries[it]) }))
        }
        add(LCDMenuEntry("端末ユーザー変更", "YESで変更", action = { if (!state.loading && state.ptt.state == PttState.IDLE) { manager.resetDeviceAssignment(); onLcdModeChange(null) } }, confirm = true))
        if (state.diagnostics.audioAvailabilityState in setOf(AudioAvailabilityState.INTERRUPTED, AudioAvailabilityState.RECOVERY_FAILED)) add(LCDMenuEntry("音声を再接続", "決定で再接続", action = manager::retryAudioRecovery))
        add(LCDMenuEntry("レベルメーター", "音声の強さを表示"))
    }
    fun menuStep(direction: Int) {
        if (lcdMode == "power" || menuLevel == 2) { confirmYes = direction > 0; return }
        if (lcdMode != "settings") return
        if (menuLevel == 0) settingIndex = (settingIndex + direction + menuEntries.size) % menuEntries.size
        else { val count = menuEntries[settingIndex.coerceAtMost(menuEntries.lastIndex)].choices.size; if (count > 0) choiceIndex = (choiceIndex + direction + count) % count }
    }
    fun menuSelect() {
        if (lcdMode == "power") { if (confirmYes) manager.leaveAsync(); onLcdModeChange(null); return }
        if (lcdMode != "settings") return
        val item = menuEntries[settingIndex.coerceAtMost(menuEntries.lastIndex)]
        when (menuLevel) {
            1 -> { if (choiceIndex in item.choices.indices) item.onChoice?.invoke(choiceIndex); menuLevel = 0 }
            2 -> { if (confirmYes) item.action?.invoke(); menuLevel = 0 }
            else -> if (item.choices.isNotEmpty()) { choiceIndex = item.selected.coerceIn(0, item.choices.lastIndex); menuLevel = 1 }
                    else if (item.confirm) { confirmYes = false; menuLevel = 2 }
                    else item.action?.invoke()
        }
    }
    fun menuCancel() { if (lcdMode == "settings" && menuLevel > 0) menuLevel = 0 else onLcdModeChange(null) }
    if (showBackgroundConsent) androidx.compose.material3.AlertDialog(
        onDismissRequest = { showBackgroundConsent = false },
        title = { Text("背景の音量ボタンで送信") },
        text = { Text("Accessibilityサービスで音量ボタンの押下・解放を検出します。参加中は約0.6秒以上の長押しで送信開始・停止を切り替えます。短押しは解放時に音量を1段階調整します。画面内容は取得せず、音量以外のキーを記録・送信しません。背景設定とOSサービスをOFFにすると無効になります。ロック中も誤って押すと送信する場合があります。") },
        confirmButton = { Button(onClick = { manager.setBackgroundVolumePttEnabled(true); showBackgroundConsent = false }) { Text("同意して有効化") } },
        dismissButton = { Button(onClick = { showBackgroundConsent = false }) { Text("キャンセル") } },
    )
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
    ConsoleSectionDivider("INDICATOR", Color(0xFFE66D9E))
    val lcdBrush = if (LocalLcdBlue.current) androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Color(0xFF123A9C), Color(0xFF09245F))) else androidx.compose.ui.graphics.Brush.verticalGradient(listOf(KoeonLcd, KoeonLcd.copy(alpha = .88f)))
    Card(colors = CardDefaults.cardColors(containerColor = Color.Transparent, contentColor = ConsoleLcdInk), shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp), modifier = Modifier.fillMaxWidth().requiredHeight(202.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp)).background(lcdBrush).border(5.dp, if (LocalConsoleDark.current) Color(0xFF10140E) else Color(0xFFAEB5A6), androidx.compose.foundation.shape.RoundedCornerShape(8.dp))) {
        Column(Modifier.fillMaxSize().padding(12.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(2.dp)), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (lcdMode == "power") {
                Text("POWER / 電源を切る", fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Bold)
                Text("送受信を終了します", fontSize = 22.sp, lineHeight = 27.sp, fontWeight = FontWeight.Bold)
                Text(if (confirmYes) "NO    ▶ YES" else "▶ NO    YES", fontSize = 24.sp, lineHeight = 30.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                Text("外周で選択 · 中央/確定で決定", fontSize = 12.sp, lineHeight = 16.sp)
            } else if (lcdMode == "settings") {
                val item = menuEntries[settingIndex.coerceAtMost(menuEntries.lastIndex)]
                Text("SETTINGS  ${settingIndex + 1}/${menuEntries.size}", fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Bold)
                Text(item.title, fontSize = 22.sp, lineHeight = 27.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(when (menuLevel) { 1 -> item.choices.getOrNull(choiceIndex)?.let { "▶ $it" } ?: item.value; 2 -> if (confirmYes) "NO    ▶ YES" else "▶ NO    YES"; else -> item.value }, fontSize = 20.sp, lineHeight = 25.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(if (menuLevel == 0) "外周: 項目  中央/確定: 選択" else "外周: 値  中央/確定: 決定", fontSize = 11.sp, lineHeight = 14.sp)
                Text("取消: ${if (menuLevel == 0) "終了" else "戻る"}", fontSize = 11.sp, lineHeight = 14.sp)
            } else if (digits != null) {
                Text("CHANNEL EDIT / 変更元 → 変更先", fontSize = 11.sp, lineHeight = 14.sp)
                Text("FROM  ${joined.channel.name}", fontSize = 20.sp, lineHeight = 23.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, softWrap = false)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("TO CH", fontSize = 24.sp, lineHeight = 27.sp)
                    repeat(digitCount) { index ->
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(digits!!.getOrNull(index)?.toString() ?: "_", fontSize = 30.sp, lineHeight = 33.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                            Box(Modifier.width(20.dp).height(3.dp).background(if (pendingChannelId == null && index == digits!!.length && cursorOn) ConsoleLcdInk else Color.Transparent))
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
    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(70.dp)) { ConsoleLamp("PTT", pttColor) }
            Box(Modifier.weight(1f)) { ConsoleMeter("TX IN", if (pttSemantic == PttSemanticState.TALKING) state.transmitInputLevelDbfs else null, KoeonSuccess) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(70.dp)) { ConsoleLamp("RX", if (state.diagnostics.rx.state in setOf(com.dennomuso.koeon.core.ptt.RxState.RX_ACTIVE, com.dennomuso.koeon.core.ptt.RxState.RX_DRAINING) || (state.diagnostics.rx.state != com.dennomuso.koeon.core.ptt.RxState.RX_IDLE && state.receiveLevelDbfs != null)) Color(0xFF328BDF) else Color.Gray.copy(alpha = .4f)) }
            Box(Modifier.weight(1f)) { ConsoleMeter("RX", if (state.connectionState == IntercomConnectionState.CONNECTED) state.receiveLevelDbfs else null, Color(0xFF328BDF)) }
        }
    }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        ConsoleSectionDivider("CHANNEL SELECT", Color(0xFF64C9E6), Modifier.weight(1f))
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
                        contentColor = ConsoleKeyInk,
                        disabledContentColor = Color(0xFF888888)
                    ),
                    modifier = Modifier.weight(1f).height(44.dp).consoleKeyFace().channelLED(keyDigits.ones == number, keyDigits.tens == number, flashRed).semantics { stateDescription = if (keyDigits.ones == number && keyDigits.tens == number) "1の位・10の位" else if (keyDigits.ones == number) "1の位" else if (keyDigits.tens == number) "10の位" else "消灯" },
                ) {
                    Text(number.toString(), fontSize = 20.sp, lineHeight = 23.sp, fontWeight = FontWeight.Bold, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                }
            }
        }
    }
    Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
        ConsoleMockKey("※", "mock.mark")
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ConsoleActionKey("2桁", channelEnabled, twoDigitActive) { resetRejection(); pendingChannelId = null; digitCount = 2; digits = "" }
        ConsoleActionKey("確定", lcdMode != null || (channelEnabled && ChannelSwitchPolicy.canConfirm(digits, digitCount, pendingChannelId != null && candidate != null))) {
            if (lcdMode != null) menuSelect()
            else if (candidate != null) { manager.switchChannel(candidate.id); resetRejection(); digits = null; pendingChannelId = null }
            else { entryRejected = true; rejectionSequence += 1; view.announceForAccessibility("未割り当てのCHです") }
        }
        ConsoleActionKey("取消", lcdMode != null || digits != null) { if (lcdMode != null) menuCancel() else { resetRejection(); digits = null; pendingChannelId = null } }
        }
        Spacer(Modifier.weight(1f))
        ConsoleMockKey("#", "mock.hash")
    }
    ConsoleSectionDivider("ACTION", if (LocalConsoleDark.current) Color(0xFF8B918D) else Color.Black)
    BoxWithConstraints(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
    val diameter = minOf(maxHeight, maxWidth - 100.dp, 220.dp)
    val mockWidth = ((maxWidth - diameter) / 2 - 6.dp).coerceIn(44.dp, 96.dp)
    val mockHeight = minOf(90.dp, maxHeight / 2 - 4.dp)
    ConsoleMockCorner("LOG", "mock.log", mockWidth, mockHeight, false, false, Modifier.align(Alignment.TopStart))
    ConsoleMockCorner("AI", "mock.ai", mockWidth, mockHeight, true, false, Modifier.align(Alignment.TopEnd))
    ConsoleMockCorner("MODE", "mock.mode", mockWidth, mockHeight, false, true, Modifier.align(Alignment.BottomStart))
    ConsoleMockCorner("Fn", "mock.fn", mockWidth, mockHeight, true, true, Modifier.align(Alignment.BottomEnd))
    if (lcdMode != null) ConsoleWheelPad(diameter, ::menuStep, ::menuSelect)
    else
    Box(
        modifier = Modifier
            .size(diameter)
            .graphicsLayer {
                val pressScale = if (inputPressed) 0.97f else 1f
                scaleX = pressScale
                scaleY = pressScale
                translationY = if (inputPressed) 3.dp.toPx() else 0f
            }
            .consoleKeyFace(CircleShape)
            .pttLED(pttColor)
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
            Text("PTT", color = ConsoleKeyInk, fontSize = 42.sp, lineHeight = 45.sp, fontWeight = FontWeight.Bold, letterSpacing = 3.sp)
            Text(pttSemantic.name.replace('_', ' '), color = ConsoleKeyInk, fontSize = 14.sp, lineHeight = 17.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        }
    }

    }
}

private data class LCDMenuEntry(
    val title: String,
    val value: String,
    val choices: List<String> = emptyList(),
    val selected: Int = 0,
    val onChoice: ((Int) -> Unit)? = null,
    val action: (() -> Unit)? = null,
    val confirm: Boolean = false,
)

@Composable
private fun ConsoleWheelPad(diameter: androidx.compose.ui.unit.Dp, onStep: (Int) -> Unit, onSelect: () -> Unit) {
    val currentStep by rememberUpdatedState(onStep)
    val currentSelect by rememberUpdatedState(onSelect)
    Box(
        Modifier.size(diameter).consoleKeyFace(CircleShape).pttLED(Color(0xFF54CBE5))
            .semantics {
                testTag = "lcd.wheel"
                contentDescription = "設定ホイール。外周を時計回りで次、反時計回りで前。中央で決定"
                onClick("決定") { currentSelect(); true }
                customActions = listOf(
                    CustomAccessibilityAction("次の項目") { currentStep(1); true },
                    CustomAccessibilityAction("前の項目") { currentStep(-1); true },
                )
            }
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    val center = androidx.compose.ui.geometry.Offset(size.width / 2f, size.height / 2f)
                    val rim = (down.position - center).getDistance() >= minOf(size.width, size.height) * .31f
                    var previous = kotlin.math.atan2(down.position.y - center.y, down.position.x - center.x)
                    var accumulated = 0f
                    var moved = false
                    down.consume()
                    while (true) {
                        val event = awaitPointerEvent(pass = PointerEventPass.Initial)
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) {
                            if (!rim && !moved) currentSelect()
                            change.consume(); break
                        }
                        if ((change.position - down.position).getDistance() > 18.dp.toPx()) moved = true
                        if (rim) {
                            val angle = kotlin.math.atan2(change.position.y - center.y, change.position.x - center.x)
                            accumulated += kotlin.math.atan2(kotlin.math.sin(angle - previous), kotlin.math.cos(angle - previous))
                            previous = angle
                            val threshold = (Math.PI / 6).toFloat()
                            while (kotlin.math.abs(accumulated) >= threshold) {
                                val direction = if (accumulated > 0) 1 else -1
                                currentStep(direction)
                                accumulated -= direction * threshold
                            }
                        }
                        change.consume()
                    }
                }
            }, contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("SELECT", color = ConsoleKeyInk, fontSize = 27.sp, lineHeight = 31.sp, fontWeight = FontWeight.Bold)
            Text("↺  TURN  ↻", color = ConsoleKeyInk, fontSize = 13.sp, lineHeight = 16.sp)
            Text("PRESS · 決定", color = ConsoleKeyInk, fontSize = 12.sp, lineHeight = 15.sp)
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
private fun ConsoleAppearancePicker(title: String, selected: String, choices: List<Pair<String, String>>, onSelect: (String) -> Unit) {
    Text(title, fontWeight = FontWeight.Bold)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        choices.forEach { (id, label) ->
            Button(onClick = { onSelect(id) }, modifier = Modifier.weight(1f).height(44.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(2.dp),
                colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = if (id == selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant),
            ) { Text(label, fontSize = if (choices.size == 4) 10.sp else 12.sp, maxLines = 1) }
        }
    }
}

@Composable
private fun ConsoleSectionDivider(title: String, ruleColor: Color, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().semantics { contentDescription = title }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, color = if (LocalConsoleDark.current) Color(0xFFD2D5D0) else Color(0xFF333631), fontSize = 11.sp, lineHeight = 14.sp, letterSpacing = 1.sp, fontWeight = FontWeight.SemiBold, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace, maxLines = 1)
        Box(Modifier.weight(1f).height(3.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(2.dp))
            .background(androidx.compose.ui.graphics.Brush.horizontalGradient(listOf(ruleColor, ruleColor.copy(alpha = .85f), ruleColor.copy(alpha = .55f))))) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = .22f)))
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
        // The LED line sits inside the key; each stroke spreads equally inward and outward.
        val inset = 6.dp.toPx()
        val ledSize = androidx.compose.ui.geometry.Size(size.width - inset * 2, size.height - inset * 2)
        for (width in 12 downTo 2 step 2) {
            drawRoundRect(brush, topLeft = androidx.compose.ui.geometry.Offset(inset, inset), size = ledSize,
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(5.dp.toPx()),
                style = androidx.compose.ui.graphics.drawscope.Stroke(width.dp.toPx()),
                alpha = if (width == 2) .85f else .065f)
        }
        drawContent()
    }
}

private fun Modifier.pttLED(color: Color): Modifier = clip(CircleShape).drawWithContent {
    val radius = size.minDimension / 2 - 9.dp.toPx()
    for (width in 18 downTo 2 step 2) {
        drawCircle(color, radius = radius, style = androidx.compose.ui.graphics.drawscope.Stroke(width.dp.toPx()),
            alpha = if (width == 2) .85f else .055f)
    }
    drawContent()
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
    val dark = LocalKeyDark.current
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
private fun ConsoleMockKey(label: String, id: String) {
    Button(onClick = {}, modifier = Modifier.width(52.dp).height(44.dp).consoleKeyFace().semantics { testTag = id; contentDescription = label },
        shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(2.dp),
        colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = ConsoleKeyInk)) {
        Text(label, fontSize = 18.sp)
    }
}

private fun cornerMockShape(flipX: Boolean, flipY: Boolean): androidx.compose.ui.graphics.Shape = androidx.compose.foundation.shape.GenericShape { size, _ ->
    val w = size.width; val h = size.height; val r = 10f; val cut = minOf(35f, w * .48f, h * .48f)
    fun p(x: Float, y: Float) = androidx.compose.ui.geometry.Offset(if (flipX) w - x else x, if (flipY) h - y else y)
    val a = p(r, 0f); moveTo(a.x, a.y)
    val b = p(w-r, 0f); lineTo(b.x, b.y)
    val c = p(w, 0f); val d = p(w, r); quadraticBezierTo(c.x, c.y, d.x, d.y)
    val e = p(w, h-cut); lineTo(e.x, e.y)
    val f = p(w-cut, h-cut); val g = p(w-cut, h); quadraticBezierTo(f.x, f.y, g.x, g.y)
    val i = p(r, h); lineTo(i.x, i.y)
    val j = p(0f, h); val k = p(0f, h-r); quadraticBezierTo(j.x, j.y, k.x, k.y)
    val l = p(0f, r); lineTo(l.x, l.y)
    val m = p(0f, 0f); quadraticBezierTo(m.x, m.y, a.x, a.y); close()
}

@Composable
private fun ConsoleMockCorner(label: String, id: String, width: androidx.compose.ui.unit.Dp, height: androidx.compose.ui.unit.Dp,
    flipX: Boolean, flipY: Boolean, modifier: Modifier = Modifier) {
    val shape = remember(flipX, flipY) { cornerMockShape(flipX, flipY) }
    Button(onClick = {}, modifier = modifier.size(width, height).consoleKeyFace(shape).semantics { testTag = id; contentDescription = label },
        shape = shape, contentPadding = androidx.compose.foundation.layout.PaddingValues(2.dp),
        colors = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = ConsoleKeyInk)) {
        Text(label, fontSize = 14.sp, maxLines = 1)
    }
}

@Composable
private fun Modifier.consoleKeyFace(shape: androidx.compose.ui.graphics.Shape = androidx.compose.foundation.shape.RoundedCornerShape(7.dp)): Modifier {
    val face = androidx.compose.ui.graphics.Brush.verticalGradient(
        if (LocalKeyDark.current) listOf(Color(0xE64A4E4B), Color(0xDE2E3330), Color(0xEB1C211E))
        else listOf(Color(0xE6FFFFFA), Color(0xD1D3D9D6), Color(0xE0E8EDE9))
    )
    val rim = androidx.compose.ui.graphics.Brush.verticalGradient(listOf(Color.White.copy(alpha = .75f), Color.White.copy(alpha = .08f), Color.Black.copy(alpha = .22f)))
    return drawBehind {
        // A translucent face must not reveal Android elevation shadow tessellation.
        val outline = shape.createOutline(size, layoutDirection, this)
        for (width in 2..10) drawOutline(outline, Color.Black.copy(alpha = .018f),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width.dp.toPx()))
    }.background(face, shape).drawWithContent {
        drawContent()
        // Draw the thin highlight directly. Brush border masking leaves an opaque
        // interior on some Android GPUs when the underlying face is translucent.
        drawOutline(shape.createOutline(size, layoutDirection, this), rim,
            style = androidx.compose.ui.graphics.drawscope.Stroke(1.dp.toPx()))
    }
}

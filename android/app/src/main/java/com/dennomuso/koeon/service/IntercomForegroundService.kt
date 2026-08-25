package com.dennomuso.koeon.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.view.KeyEvent
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.dennomuso.koeon.KoeonApplication
import com.dennomuso.koeon.MainActivity
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.lang.ref.WeakReference

class IntercomForegroundService : Service() {
    private var transientWakeLock: PowerManager.WakeLock? = null
    private var mediaSession: MediaSession? = null
    private val mediaButtonPolicy = HeadsetPttPolicy()
    private val handler = Handler(Looper.getMainLooper())
    private val safetyRelease = Runnable {
        if (mediaButtonPolicy.forceRelease()) {
            (application as KoeonApplication).intercomSession.onHeadsetPttAction(
                HeadsetPttAction.UP, "safety_timeout", "synthetic_up",
            )
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running.set(true)
        activeService = WeakReference(this)
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "KOEON Intercom", NotificationManager.IMPORTANCE_LOW),
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                expectedStop.set(true)
                applyWakePolicy(BackgroundWakeEvent.STOPPED)
                (application as KoeonApplication).intercomSession.leaveAsync()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            ACTION_STOP_SERVICE -> {
                applyWakePolicy(BackgroundWakeEvent.STOPPED)
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            else -> {
                val state = intent?.getStringExtra(EXTRA_STATE) ?: "接続しています"
                val initialStart = intent?.action == ACTION_START
                applyWakePolicy(
                    if (state == STATE_RECONNECTING || initialStart) {
                        if (initialStart) BackgroundWakeEvent.SESSION_STARTING else BackgroundWakeEvent.RECONNECTING
                    } else BackgroundWakeEvent.CONNECTED,
                )
                val canPublish = intent?.getBooleanExtra(EXTRA_CAN_PUBLISH, false) == true
                val headsetPttEnabled = intent?.getBooleanExtra(EXTRA_HEADSET_PTT_ENABLED, false) == true
                showNotification(
                    intent?.getStringExtra(EXTRA_CHANNEL).orEmpty(), state, canPublish, initialStart,
                )
                configureMediaSession(headsetPttEnabled && canPublish)
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running.set(false)
        if (activeService?.get() === this) activeService = null
        handler.removeCallbacks(safetyRelease)
        mediaButtonPolicy.forceRelease()
        mediaSession?.release()
        mediaSession = null
        applyWakePolicy(BackgroundWakeEvent.STOPPED)
        super.onDestroy()
        if (!expectedStop.getAndSet(true)) {
            (application as KoeonApplication).intercomSession.onForegroundServiceDestroyed()
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Activity/task removal is not a Leave command. The application-scoped Room
        // and this ongoing service continue until the user explicitly leaves.
        super.onTaskRemoved(rootIntent)
    }

    @Suppress("WakelockTimeout")
    private fun applyWakePolicy(event: BackgroundWakeEvent) {
        when (backgroundWakeAction(event)) {
            BackgroundWakeAction.ACQUIRE_WITH_TIMEOUT -> {
                val lock = transientWakeLock ?: getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "KOEON:TransientReconnect")
                    .also { transientWakeLock = it }
                if (!lock.isHeld) lock.acquire(TRANSIENT_WAKE_LOCK_TIMEOUT_MS)
            }
            BackgroundWakeAction.RELEASE -> transientWakeLock?.takeIf { it.isHeld }?.release()
        }
    }

    private fun showNotification(channelName: String, state: String, canPublish: Boolean, initialStart: Boolean) {
        val openIntent = PendingIntent.getActivity(
            this, 1, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this, 2, Intent(this, IntercomForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_speakerphone)
            .setContentTitle("KOEON · ${channelName.ifBlank { "Channel" }}に参加中")
            .setContentText(state)
            .setOngoing(true)
            .setContentIntent(openIntent)
            .addAction(0, "退出", stopIntent)
            .build()
        if (initialStart) {
            foregroundStartCount.incrementAndGet()
            val type = when (foregroundSessionMode(canPublish)) {
                @Suppress("InlinedApi")
                ForegroundSessionMode.MICROPHONE_AND_MEDIA_PLAYBACK ->
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                ForegroundSessionMode.MEDIA_PLAYBACK -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            }
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
        } else {
            notificationUpdateCount.incrementAndGet()
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
        }
    }

    private fun configureMediaSession(enabled: Boolean) {
        if (!enabled) {
            if (mediaButtonPolicy.forceRelease()) {
                (application as KoeonApplication).intercomSession.onHeadsetPttAction(
                    HeadsetPttAction.UP, "setting_or_role_disabled", "synthetic_up",
                )
            }
            handler.removeCallbacks(safetyRelease)
            mediaSession?.isActive = false
            mediaSession?.release()
            mediaSession = null
            return
        }
        if (mediaSession != null) return
        mediaSession = MediaSession(this, "KOEON Headset PTT").apply {
            setPlaybackState(
                PlaybackState.Builder()
                    .setActions(
                        PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                            PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP,
                    )
                    .setState(PlaybackState.STATE_PAUSED, 0, 1f)
                    .build(),
            )
            setCallback(object : MediaSession.Callback() {
                @Suppress("DEPRECATION")
                override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                    val event = mediaButtonIntent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT) ?: return false
                    val session = (application as KoeonApplication).intercomSession
                    val eligibility = session.headsetPttEligibility()
                    val action = mediaButtonPolicy.evaluate(event, eligibility)
                    if (action == HeadsetPttAction.IGNORE) return event.keyCode in HeadsetPttPolicy.SUPPORTED_KEYS
                    handler.removeCallbacks(safetyRelease)
                    if (action == HeadsetPttAction.DOWN && eligibility.mode == HeadsetPttMode.MOMENTARY) {
                        // Some accessories never deliver UP. Never leave TX latched.
                        handler.postDelayed(safetyRelease, HEADSET_PTT_SAFETY_RELEASE_MS)
                    }
                    session.onHeadsetPttAction(
                        action, KeyEvent.keyCodeToString(event.keyCode), event.action.toString(),
                    )
                    return true
                }
            })
            isActive = true
        }
    }

    private fun applyRunningUpdate(
        channelName: String,
        canPublish: Boolean,
        state: String,
        headsetPttEnabled: Boolean,
    ) {
        applyWakePolicy(if (state == STATE_RECONNECTING) BackgroundWakeEvent.RECONNECTING else BackgroundWakeEvent.CONNECTED)
        showNotification(channelName, state, canPublish, initialStart = false)
        configureMediaSession(headsetPttEnabled && canPublish)
    }

    companion object {
        private const val CHANNEL_ID = "koeon_intercom"
        private const val NOTIFICATION_ID = 2002
        private const val ACTION_START = "com.dennomuso.koeon.START_INTERCOM"
        private const val ACTION_UPDATE = "com.dennomuso.koeon.UPDATE_INTERCOM"
        private const val ACTION_STOP = "com.dennomuso.koeon.LEAVE_INTERCOM"
        private const val ACTION_STOP_SERVICE = "com.dennomuso.koeon.STOP_SERVICE"
        private const val EXTRA_CHANNEL = "channel"
        private const val EXTRA_STATE = "state"
        private const val EXTRA_CAN_PUBLISH = "can_publish"
        private const val EXTRA_HEADSET_PTT_ENABLED = "headset_ptt_enabled"
        const val STATE_RECONNECTING = "再接続中"
        private const val HEADSET_PTT_SAFETY_RELEASE_MS = 5_000L
        private val expectedStop = AtomicBoolean(true)
        private val running = AtomicBoolean(false)
        private val foregroundStartCount = AtomicInteger(0)
        private val notificationUpdateCount = AtomicInteger(0)
        @Volatile private var activeService: WeakReference<IntercomForegroundService>? = null

        fun start(context: Context, channelName: String, canPublish: Boolean, headsetPttEnabled: Boolean) {
            expectedStop.set(false)
            ContextCompat.startForegroundService(
                context,
                intent(context, ACTION_START, channelName, canPublish, "接続しています", headsetPttEnabled),
            )
        }

        fun update(channelName: String, canPublish: Boolean, state: String, headsetPttEnabled: Boolean) {
            val service = activeService?.get() ?: return
            // Update the already-running service directly. No startService or
            // startForegroundService request occurs from background.
            service.handler.post {
                service.applyRunningUpdate(channelName, canPublish, state, headsetPttEnabled)
            }
        }

        fun stop(context: Context) {
            expectedStop.set(true)
            context.stopService(Intent(context, IntercomForegroundService::class.java))
        }

        fun diagnostics(): ForegroundServiceDiagnostics = ForegroundServiceDiagnostics(
            running.get(), foregroundStartCount.get(), notificationUpdateCount.get(),
        )

        fun resetHeadsetLatch() {
            val service = activeService?.get() ?: return
            service.handler.post {
                service.handler.removeCallbacks(service.safetyRelease)
                service.mediaButtonPolicy.forceRelease()
            }
        }

        private fun intent(
            context: Context,
            action: String,
            channel: String,
            canPublish: Boolean,
            state: String,
            headsetPttEnabled: Boolean,
        ) = Intent(context, IntercomForegroundService::class.java)
            .setAction(action)
            .putExtra(EXTRA_CHANNEL, channel)
            .putExtra(EXTRA_CAN_PUBLISH, canPublish)
            .putExtra(EXTRA_STATE, state)
            .putExtra(EXTRA_HEADSET_PTT_ENABLED, headsetPttEnabled)
    }
}

data class ForegroundServiceDiagnostics(
    val running: Boolean,
    val foregroundStartCount: Int,
    val notificationUpdateCount: Int,
)

internal enum class ForegroundServiceDelivery { START_FOREGROUND, UPDATE_RUNNING_SERVICE, IGNORE }

internal fun foregroundServiceDelivery(initialJoin: Boolean, serviceRunning: Boolean): ForegroundServiceDelivery = when {
    initialJoin -> ForegroundServiceDelivery.START_FOREGROUND
    serviceRunning -> ForegroundServiceDelivery.UPDATE_RUNNING_SERVICE
    else -> ForegroundServiceDelivery.IGNORE
}

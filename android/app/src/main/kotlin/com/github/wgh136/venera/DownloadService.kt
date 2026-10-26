package com.github.wgh136.venera

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/// Keeps downloads running while the app is in the background: a
/// foreground service with a wake lock, whose notification shows the
/// progress of the first task and pauses or resumes it.
///
/// The downloads run in Dart, which sends their state through [update]
/// once a second while a task runs and through [finish] when the queue is
/// empty. The service runs only while a task runs: a paused or failed task
/// leaves a notification to resume it, if the pause came from the
/// notification.
class DownloadService : Service() {
    /// What Dart reports about the first task.
    data class Status(
        /// "running", "paused" or "error"
        val state: String,
        val title: String,
        val text: String,
        val subText: String?,
        /// 0-1, negative while unknown
        val progress: Double,
        val pauseLabel: String,
        val resumeLabel: String,
    ) {
        val running get() = state == "running"
    }

    companion object {
        private const val TAG = "DownloadService"
        private const val CHANNEL_ID = "downloads"
        /// The notification of the running service.
        private const val NOTIFICATION_ID = 0x7d01

        /// The notification left when the service stops. Not the one of the
        /// service: Android updates that one after the service stops, which
        /// would overwrite what is posted in its place.
        private const val STATUS_NOTIFICATION_ID = 0x7d02
        private const val ACTION_PAUSE = "com.github.wgh136.venera.PAUSE_DOWNLOAD"
        private const val ACTION_RESUME = "com.github.wgh136.venera.RESUME_DOWNLOAD"

        /// An extra of the intent that opens the app to resume the downloads.
        const val EXTRA_RESUME = "venera.resume_downloads"

        /// Without updates for this long, Dart is gone or stuck.
        private const val WATCHDOG_MS = 2 * 60_000L
        private const val WAKE_LOCK_MS = 5 * 60_000L

        /// Sends "pause" or "resume" to Dart; null while no Flutter engine runs.
        var onAction: ((String) -> Unit)? = null

        private var status: Status? = null
        private var lastUpdate = 0L

        /// Why the task was paused by the service, which decides what the
        /// notification of the paused task says.
        private var pausedBy: String? = null

        /// What the notification shows while the service does not run.
        private var pending: Notification? = null

        private var instance: DownloadService? = null
        private var starting = false

        /// Android refused to start the service, e.g. in the background:
        /// tried again when the app is visible.
        private var refused = false

        fun update(context: Context, s: Status) {
            status = s
            lastUpdate = SystemClock.elapsedRealtime()
            if (s.running) {
                // [pausedBy] waits for the update of the paused task: this
                // one may have been sent before Dart paused it.
                val service = instance
                if (service != null) {
                    service.show(s)
                } else if (!starting && !refused) {
                    start(context)
                }
                return
            }
            refused = false
            pending = when {
                s.state == "error" -> stoppedNotification(context, s)
                pausedBy == "notification" -> stoppedNotification(context, s)
                pausedBy == "timeout" -> interruptedNotification(context, R.string.download_time_limit)
                else -> null
            }
            pausedBy = null
            instance?.stop()
            showPending(context)
        }

        /// Called when no task is left; [title] and [text] tell which
        /// downloads have completed, if any.
        fun finish(context: Context, title: String?, text: String?) {
            status = null
            pausedBy = null
            refused = false
            pending = if (title == null) null else builder(context)
                .setContentTitle(title)
                .setContentText(text)
                .setAutoCancel(true)
                .build()
            instance?.stop()
            showPending(context)
        }

        /// The Flutter engine is destroyed, e.g. the app was removed from the
        /// recent apps: the downloads have stopped with it.
        fun engineGone(context: Context) {
            onAction = null
            if (status?.running == true) {
                interrupt(context, R.string.download_interrupted)
            }
        }

        fun onAppVisible(context: Context) {
            if (refused) {
                refused = false
                if (status?.running == true && instance == null && !starting) {
                    start(context)
                }
            }
        }

        private fun start(context: Context) {
            starting = true
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, DownloadService::class.java)
                )
            } catch (e: Exception) {
                // Android 12+ does not start it from the background.
                Log.w(TAG, "Cannot start the download service: $e")
                starting = false
                refused = true
            }
        }

        private fun interrupt(context: Context, message: Int) {
            pending = interruptedNotification(context, message)
            status = null
            instance?.stop()
            showPending(context)
        }

        private fun showPending(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            val notification = pending
            if (notification == null) {
                manager.cancel(STATUS_NOTIFICATION_ID)
            } else {
                manager.notify(STATUS_NOTIFICATION_ID, notification)
            }
        }

        private fun builder(context: Context): NotificationCompat.Builder {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.getSystemService(NotificationManager::class.java)
                    .createNotificationChannel(
                        NotificationChannel(
                            CHANNEL_ID,
                            context.getString(R.string.download_channel),
                            NotificationManager.IMPORTANCE_LOW
                        )
                    )
            }
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification_download)
                .setContentIntent(openApp(context, false))
                .setShowWhen(false)
                .setOnlyAlertOnce(true)
        }

        private fun runningNotification(context: Context, s: Status): Notification {
            val pause = PendingIntent.getService(
                context,
                2,
                Intent(context, DownloadService::class.java).setAction(ACTION_PAUSE),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val progress = (s.progress * 1000).toInt().coerceIn(0, 1000)
            return builder(context)
                .setContentTitle(s.title)
                .setContentText(s.text)
                .setSubText(s.subText)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setOngoing(true)
                .setProgress(1000, progress, s.progress < 0)
                .addAction(0, s.pauseLabel, pause)
                .build()
        }

        private fun stoppedNotification(context: Context, s: Status): Notification {
            val intent = Intent(context, DownloadService::class.java).setAction(ACTION_RESUME)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val resume = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PendingIntent.getForegroundService(context, 3, intent, flags)
            } else {
                PendingIntent.getService(context, 3, intent, flags)
            }
            return builder(context)
                .setContentTitle(s.title)
                .setContentText(s.text)
                .setSubText(s.subText)
                .setAutoCancel(true)
                .addAction(0, s.resumeLabel, resume)
                .build()
        }

        /// Opens the app, which then resumes the downloads.
        private fun interruptedNotification(context: Context, message: Int): Notification {
            return builder(context)
                .setContentTitle(status?.title ?: context.getString(R.string.download_channel))
                .setContentText(context.getString(message))
                .setStyle(NotificationCompat.BigTextStyle().bigText(context.getString(message)))
                .setContentIntent(openApp(context, true))
                .setAutoCancel(true)
                .build()
        }

        private fun openApp(context: Context, resume: Boolean): PendingIntent {
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)
            if (resume) {
                intent.putExtra(EXTRA_RESUME, true)
            }
            return PendingIntent.getActivity(
                context,
                if (resume) 1 else 0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var wakeLockRenewed = 0L
    private var foreground = false
    private var lastStartId = 0

    private val watchdog = object : Runnable {
        override fun run() {
            if (SystemClock.elapsedRealtime() - lastUpdate > WATCHDOG_MS) {
                Log.w(TAG, "No download updates for ${WATCHDOG_MS / 1000} s")
                interrupt(this@DownloadService, R.string.download_interrupted)
                return
            }
            handler.postDelayed(this, 30_000L)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        starting = false
        lastStartId = startId
        when (intent?.action) {
            ACTION_PAUSE -> {
                val action = onAction
                if (action == null) {
                    interrupt(this, R.string.download_interrupted)
                } else {
                    pausedBy = "notification"
                    action("pause")
                }
            }

            ACTION_RESUME -> {
                // Started as a foreground service: it must enter the
                // foreground even if it cannot resume anything.
                val s = status
                val action = onAction
                if (s == null || action == null) {
                    enterForeground(interruptedNotification(this, R.string.download_interrupted))
                    interrupt(this, R.string.download_interrupted)
                } else if (enterForeground(runningNotification(this, s.copy(progress = -1.0)))) {
                    renewWakeLock()
                    lastUpdate = SystemClock.elapsedRealtime()
                    action("resume")
                } else {
                    // e.g. the daily time limit of Android 15 is used up.
                    interrupt(this, R.string.download_time_limit)
                }
            }

            else -> {
                val s = status
                if (s != null && s.running) {
                    show(s)
                } else {
                    // Stopped before the service came up. It must still
                    // enter the foreground once, as it was started for that.
                    if (enterForeground(runningNotification(this, s ?: placeholder()))) {
                        stop()
                    }
                    showPending(this)
                }
            }
        }
        // Never restarted by the system: Dart, which runs the downloads,
        // would not be running then.
        return START_NOT_STICKY
    }

    private fun placeholder() = Status(
        "running", getString(R.string.download_channel), "", null, -1.0, "", ""
    )

    fun show(s: Status) {
        val notification = runningNotification(this, s)
        if (foreground) {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
        } else if (!enterForeground(notification)) {
            refused = true
            return
        }
        renewWakeLock()
    }

    /// Returns false if Android refuses, and the service is then stopped.
    private fun enterForeground(notification: Notification): Boolean {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Cannot enter the foreground: $e")
            stop()
            return false
        }
        if (!foreground) {
            foreground = true
            handler.postDelayed(watchdog, 30_000L)
            getSystemService(NotificationManager::class.java).cancel(STATUS_NOTIFICATION_ID)
        }
        return true
    }

    private fun renewWakeLock() {
        val now = SystemClock.elapsedRealtime()
        val lock = wakeLock ?: (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "venera:downloads")
            .also {
                it.setReferenceCounted(false)
                wakeLock = it
            }
        if (!lock.isHeld || now - wakeLockRenewed > 30_000L) {
            // Acquiring it again restarts the timeout.
            lock.acquire(WAKE_LOCK_MS)
            wakeLockRenewed = now
        }
    }

    /// Leaves the foreground and removes its notification: [showPending]
    /// shows what follows.
    fun stop() {
        if (instance === this) {
            instance = null
        }
        handler.removeCallbacksAndMessages(null)
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        if (foreground) {
            foreground = false
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        stopSelf(lastStartId)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15 runs data sync services at most 6 hours a day.
        Log.w(TAG, "The download service timed out")
        val action = onAction
        if (action != null) {
            pausedBy = "timeout"
            action("pause")
        }
        if (instance === this) {
            interrupt(this, R.string.download_time_limit)
        }
    }

    override fun onDestroy() {
        if (instance === this) {
            stop()
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

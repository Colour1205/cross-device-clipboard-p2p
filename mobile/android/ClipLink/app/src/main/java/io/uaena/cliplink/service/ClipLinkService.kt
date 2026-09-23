package io.uaena.cliplink.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.uaena.cliplink.ClipLinkApplication
import io.uaena.cliplink.MainActivity
import io.uaena.cliplink.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Keeps the process - and therefore every peer connection - alive with the
 * app closed.
 *
 * TYPE IS `connectedDevice`, DELIBERATELY NOT `dataSync`. Since Android 15 an
 * app's dataSync services share a 6-hour budget per 24 hours, after which the
 * system calls onTimeout and then throws RemoteServiceException if the
 * service hasn't stopped itself - and starting a new one once the budget is
 * spent throws ForegroundServiceStartNotAllowedException. A clipboard link
 * that is supposed to stay reachable would hit that every day.
 * `connectedDevice` is documented for interactions with external devices over
 * "Bluetooth, NFC, IR, USB, or network connections" and has no time limit at
 * all. It does require the app to hold one of CHANGE_WIFI_MULTICAST_STATE /
 * CHANGE_NETWORK_STATE / CHANGE_WIFI_STATE at runtime - see the manifest.
 */
class ClipLinkService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var notificationJob: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        startForegroundCompat(buildNotification("Starting…"))

        val engine = ClipLinkApplication.engine()
        engine.start()

        notificationJob?.cancel()
        notificationJob = scope.launch {
            combine(engine.connectedCount, engine.discoveryRunning) { count, discovering ->
                when {
                    count > 0 -> "Connected to $count device${if (count == 1) "" else "s"}"
                    discovering -> "Looking for your devices…"
                    else -> "Not discovering - check local network permission"
                }
            }.collect { text ->
                notificationManager().notify(NOTIFICATION_ID, buildNotification(text))
            }
        }

        // START_STICKY so the system brings this back after killing it for
        // memory - the whole point is being reachable without the user
        // reopening the app.
        return START_STICKY
    }

    override fun onDestroy() {
        notificationJob?.cancel()
        scope.coroutineContext[Job]?.cancel()
        super.onDestroy()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, ClipLinkService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentIntent(open)
            .addAction(
                Notification.Action.Builder(null, "Stop", stop).build(),
            )
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.service_channel_name),
            // LOW so the ongoing notification never makes a sound or peeks -
            // it exists because the platform requires it, not to be read.
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.service_channel_description)
            setShowBadge(false)
        }
        notificationManager().createNotificationChannel(channel)
    }

    private fun notificationManager() =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    companion object {
        private const val CHANNEL_ID = "cliplink_sync"
        private const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "io.uaena.cliplink.STOP"

        fun start(context: Context) {
            val intent = Intent(context, ClipLinkService::class.java)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ClipLinkService::class.java))
        }
    }
}

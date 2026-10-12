// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.luohoa97.ramblevoice.bubble

import io.github.luohoa97.ramblevoice.CrashLog
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.github.luohoa97.ramblevoice.R

/**
 * Notices when the floating mic has been switched off behind the user's back
 * (some OEM battery managers disable accessibility services of killed apps)
 * and tells them, with a one-tap way back to the switch.
 *
 * It never changes accessibility settings itself: turning the service on is
 * always the user's action. "Wanted" is learned from the service having been
 * on, and cleared only by the user's "Turn off" in Ramble Voice's settings.
 */
object BubbleKeeper {
    private const val CHANNEL_ID = "bubble_keeper"
    private const val NOTICE_ID = 4201
    private const val PERIODIC_JOB_ID = 4202
    private const val SOON_JOB_ID = 4203
    private const val PERIOD_MS = 15 * 60 * 1000L
    private const val SOON_MS = 10_000L

    fun isEnabled(context: Context): Boolean {
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            ?: return false
        val own = ComponentName(context, RambleBubbleService::class.java)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == own }
    }

    /** Remembers that the user has the bubble on, then reconciles the notice. */
    fun sync(context: Context) {
        val app = context.applicationContext
        if (isEnabled(app)) BubblePrefs(app).wanted = true
        check(app)
    }

    fun canWriteSecureSettings(context: Context): Boolean =
        context.checkSelfPermission(android.Manifest.permission.WRITE_SECURE_SETTINGS) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    /**
     * Opt-in auto-restore. Only when the user turned on "Auto-restore floating
     * mic" in Ramble AND granted WRITE_SECURE_SETTINGS over adb: re-adds our
     * service to the enabled list (other services are kept). Returns true when
     * the service is enabled afterwards. With the toggle off it never touches
     * secure settings, so switching the toggle off first lets the user turn
     * the floating mic off for good.
     */
    fun restoreIfAllowed(context: Context): Boolean {
        val app = context.applicationContext
        val prefs = BubblePrefs(app)
        if (!prefs.autoRestore || !prefs.wanted || isEnabled(app) || !canWriteSecureSettings(app)) return isEnabled(app)
        return try {
            val resolver = app.contentResolver
            val own = ComponentName(app, RambleBubbleService::class.java).flattenToString()
            val current = Settings.Secure.getString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
            val entries = current.split(':').filter { it.isNotBlank() && it != own }
            Settings.Secure.putString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, (entries + own).joinToString(":"))
            Settings.Secure.putInt(resolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
            CrashLog.note("bubble auto-restored")
            isEnabled(app)
        } catch (e: SecurityException) {
            false
        }
    }

    /** Posts the "turned off" notice if the bubble is wanted but off; clears it otherwise. */
    fun check(context: Context) {
        val app = context.applicationContext
        restoreIfAllowed(app)
        val notifications = app.getSystemService(NotificationManager::class.java) ?: return
        if (!BubblePrefs(app).wanted || isEnabled(app)) {
            notifications.cancel(NOTICE_ID)
            return
        }
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, app.getString(R.string.bubble_keeper_channel), NotificationManager.IMPORTANCE_LOW),
        )
        val open = PendingIntent.getActivity(
            app,
            0,
            Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS")
                .putExtra(Intent.EXTRA_COMPONENT_NAME, ComponentName(app, RambleBubbleService::class.java).flattenToString())
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        notifications.notify(
            NOTICE_ID,
            Notification.Builder(app, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_bubble_mic)
                .setContentTitle(app.getString(R.string.bubble_keeper_title))
                .setContentText(app.getString(R.string.bubble_keeper_text))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build(),
        )
    }

    /** The user turned the bubble off in Ramble Voice's settings: stop watching. */
    fun forget(context: Context) {
        val app = context.applicationContext
        BubblePrefs(app).wanted = false
        app.getSystemService(JobScheduler::class.java)?.run {
            cancel(PERIODIC_JOB_ID)
            cancel(SOON_JOB_ID)
        }
        app.getSystemService(NotificationManager::class.java)?.cancel(NOTICE_ID)
    }

    /** Re-checks every 15 minutes, surviving reboots (needs RECEIVE_BOOT_COMPLETED). */
    fun schedulePeriodic(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        if (scheduler.getPendingJob(PERIODIC_JOB_ID) != null) return
        scheduler.schedule(
            JobInfo.Builder(PERIODIC_JOB_ID, ComponentName(context, KeeperJob::class.java))
                .setPeriodic(PERIOD_MS)
                .setPersisted(true)
                .build(),
        )
    }

    /** One quick re-check, e.g. right after the service was unbound. */
    fun scheduleSoon(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        scheduler.schedule(
            JobInfo.Builder(SOON_JOB_ID, ComponentName(context, KeeperJob::class.java))
                .setMinimumLatency(SOON_MS)
                .build(),
        )
    }

    class KeeperJob : JobService() {
        override fun onStartJob(params: JobParameters): Boolean {
            check(this)
            return false
        }

        override fun onStopJob(params: JobParameters) = false
    }

    class BootReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            sync(context)
            if (BubblePrefs(context).wanted) schedulePeriodic(context)
        }
    }
}

package com.fcwe1113.bus_arrival_notification_app

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Before the window shows, so a ring's full-screen alert appears over
        // the lock screen straight away rather than once Flutter has started.
        if (isRingIntent(intent)) setOverLockScreen(true)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        if (isRingIntent(intent)) setOverLockScreen(true)
        super.onNewIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The ring screen turns this on while it shows and off when it closes.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.fcwe1113.transport_alarm/ring_window")
            .setMethodCallHandler { call, result ->
                if (call.method == "setOverLockScreen") {
                    setOverLockScreen(call.argument<Boolean>("enabled") == true)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    /** flutter_local_notifications' tap and full-screen intents; rings' payloads start with "ring:". */
    private fun isRingIntent(intent: Intent?): Boolean =
        intent?.action == "SELECT_NOTIFICATION" &&
            intent.getStringExtra("payload")?.startsWith("ring:") == true

    /** Shows the app over the lock screen, turns the screen on and keeps it on, only while ringing. */
    private fun setOverLockScreen(enabled: Boolean) {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(enabled)
            setTurnScreenOn(enabled)
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        }
        if (enabled) window.addFlags(flags) else window.clearFlags(flags)
    }
}

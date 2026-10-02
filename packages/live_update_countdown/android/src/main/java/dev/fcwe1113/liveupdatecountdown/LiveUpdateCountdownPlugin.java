package dev.fcwe1113.liveupdatecountdown;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.graphics.Color;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

import androidx.annotation.NonNull;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.graphics.drawable.IconCompat;

import java.util.ArrayList;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.text.DateFormat;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Posts Android countdown notifications and requests Live Update promotion. */
public final class LiveUpdateCountdownPlugin implements FlutterPlugin,
        MethodChannel.MethodCallHandler {
    private static final String CHANNEL_NAME = "dev.fcwe1113.live_update_countdown";
    private static final String NOTIFICATION_CHANNEL_ID =
            "transport_alarm_status_channel";
    private static final String NOTIFICATION_CHANNEL_NAME = "Alarm updates";

    private Context context;
    private MethodChannel channel;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call,
                             @NonNull MethodChannel.Result result) {
        if (!"show".equals(call.method)) {
            result.notImplemented();
            return;
        }

        try {
            Map<?, ?> arguments = (Map<?, ?>) call.arguments;
            int id = ((Number) arguments.get("id")).intValue();
            String title = (String) arguments.get("title");
            String body = (String) arguments.get("body");
            long progressStartMillis =
                    ((Number) arguments.get("progressStartMillis")).longValue();
            long countdownTargetMillis =
                    ((Number) arguments.get("countdownTargetMillis")).longValue();
            long estimatedArrivalMillis =
                    ((Number) arguments.get("estimatedArrivalMillis")).longValue();
            List<?> thresholdTimes = (List<?>) arguments.get("thresholdTimesMillis");
            postCountdown(id, title, body, progressStartMillis,
                    countdownTargetMillis, estimatedArrivalMillis, thresholdTimes);
            result.success(true);
        } catch (Exception exception) {
            result.error("LIVE_UPDATE_FAILED", exception.getMessage(), null);
        }
    }

    private void postCountdown(int id, String title, String body,
                               long progressStartMillis,
                               long countdownTargetMillis,
                               long estimatedArrivalMillis,
                               List<?> thresholdTimes) {
        ensureNotificationChannel();

        int icon = context.getApplicationInfo().icon;
        if (icon == 0) {
            throw new IllegalStateException("App notification icon is missing.");
        }

        long nowMillis = System.currentTimeMillis();
        int progressMax = 1000;
        String etaText = DateFormat.getTimeInstance(DateFormat.SHORT)
                .format(new Date(estimatedArrivalMillis));
        long journeyMillis = Math.max(
                1L, estimatedArrivalMillis - progressStartMillis);
        int progress = (int) Math.round(
                (nowMillis - progressStartMillis) * (double) progressMax
                        / journeyMillis);
        progress = Math.max(0, Math.min(progressMax, progress));
        Set<Integer> seenPointPositions = new HashSet<>();
        List<NotificationCompat.ProgressStyle.Point> points = new ArrayList<>();
        for (Object value : thresholdTimes) {
            if (!(value instanceof Number)) continue;
            long thresholdMillis = ((Number) value).longValue();
            if (thresholdMillis <= progressStartMillis
                    || thresholdMillis >= estimatedArrivalMillis) {
                continue;
            }
            int position = (int) Math.round(
                    (thresholdMillis - progressStartMillis)
                            * (double) progressMax / journeyMillis);
            position = Math.max(1, Math.min(progressMax - 1, position));
            if (seenPointPositions.add(position)) {
                points.add(new NotificationCompat.ProgressStyle.Point(position)
                        .setColor(Color.rgb(255, 152, 0)));
            }
        }

        NotificationCompat.ProgressStyle progressStyle =
                new NotificationCompat.ProgressStyle()
                        .setProgress(progress)
                        .setProgressSegments(java.util.Collections.singletonList(
                                new NotificationCompat.ProgressStyle.Segment(progressMax)
                                        .setColor(Color.rgb(33, 150, 243))))
                        .setProgressPoints(points)
                        // Place the bus at the current time-based position; each ETA
                        // refresh reposts this notification and moves the tracker.
                        .setProgressTrackerIcon(IconCompat.createWithResource(
                                context, R.drawable.live_update_bus))
                        .setProgressStartIcon(IconCompat.createWithResource(
                                context, R.drawable.live_update_now))
                        .setProgressEndIcon(null);

        NotificationCompat.Builder notification =
                new NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID)
                        .setSmallIcon(icon)
                        .setContentTitle(title)
                        .setContentText(body + " • ETA " + etaText)
                        .setSubText("Now → bus arrival")
                        .setWhen(countdownTargetMillis)
                        .setShowWhen(true)
                        .setUsesChronometer(true)
                        .setChronometerCountDown(true)
                        .setStyle(progressStyle)
                        .setOngoing(true)
                        .setAutoCancel(false)
                        .setOnlyAlertOnce(true)
                        .setSilent(true)
                        .setRequestPromotedOngoing(true);

        Intent launchIntent = context.getPackageManager()
                .getLaunchIntentForPackage(context.getPackageName());
        if (launchIntent != null) {
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP
                    | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            PendingIntent contentIntent = PendingIntent.getActivity(
                    context,
                    id,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            notification.setContentIntent(contentIntent);
        }

        NotificationManagerCompat.from(context).notify(id, notification.build());
    }

    private void ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;

        NotificationManager manager =
                (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) return;

        NotificationChannel channel = new NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                NOTIFICATION_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_DEFAULT);
        channel.setDescription("Silent alarm countdowns and status updates.");
        channel.setSound(null, null);
        channel.enableVibration(false);
        manager.createNotificationChannel(channel);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
        context = null;
    }
}

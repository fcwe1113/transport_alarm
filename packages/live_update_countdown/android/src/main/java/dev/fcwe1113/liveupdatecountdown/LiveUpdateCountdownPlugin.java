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
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.text.DateFormat;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * Posts Android countdown notifications and requests Live Update promotion.
 * A countdown can carry one action button, which opens the app and passes
 * the action to Dart: through "takePendingAction" when it launched the app,
 * or an "onAction" call when the app was already running.
 */
public final class LiveUpdateCountdownPlugin implements FlutterPlugin,
        MethodChannel.MethodCallHandler, ActivityAware,
        PluginRegistry.NewIntentListener {
    private static final String CHANNEL_NAME = "dev.fcwe1113.live_update_countdown";
    private static final String NOTIFICATION_CHANNEL_ID =
            "transport_alarm_status_channel";
    private static final String EXTRA_ACTION =
            "dev.fcwe1113.live_update_countdown.ACTION";
    private static final String EXTRA_ACTION_ARGUMENT =
            "dev.fcwe1113.live_update_countdown.ACTION_ARGUMENT";

    private Context context;
    private MethodChannel channel;
    private ActivityPluginBinding activityBinding;
    /** An action that launched the app, until Dart takes it. */
    private Map<String, Object> pendingAction;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call,
                             @NonNull MethodChannel.Result result) {
        if ("takePendingAction".equals(call.method)) {
            result.success(pendingAction);
            pendingAction = null;
            return;
        }
        if (!"show".equals(call.method)) {
            result.notImplemented();
            return;
        }

        try {
            Map<?, ?> arguments = (Map<?, ?>) call.arguments;
            int id = ((Number) arguments.get("id")).intValue();
            String title = (String) arguments.get("title");
            String body = (String) arguments.get("body");
            // Localised by the app, which knows the alarm's transport mode.
            String subText = (String) arguments.get("subText");
            long progressStartMillis =
                    ((Number) arguments.get("progressStartMillis")).longValue();
            long countdownTargetMillis =
                    ((Number) arguments.get("countdownTargetMillis")).longValue();
            long estimatedArrivalMillis =
                    ((Number) arguments.get("estimatedArrivalMillis")).longValue();
            List<?> thresholdTimes = (List<?>) arguments.get("thresholdTimesMillis");
            // Optional: one button that opens the app with this action.
            String actionId = (String) arguments.get("actionId");
            String actionLabel = (String) arguments.get("actionLabel");
            String actionArgument = (String) arguments.get("actionArgument");
            postCountdown(id, title, body, subText, progressStartMillis,
                    countdownTargetMillis, estimatedArrivalMillis, thresholdTimes,
                    actionId, actionLabel, actionArgument);
            result.success(true);
        } catch (Exception exception) {
            result.error("LIVE_UPDATE_FAILED", exception.getMessage(), null);
        }
    }

    private void postCountdown(int id, String title, String body, String subText,
                               long progressStartMillis,
                               long countdownTargetMillis,
                               long estimatedArrivalMillis,
                               List<?> thresholdTimes,
                               String actionId,
                               String actionLabel,
                               String actionArgument) {
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

        Map<String, String> contentValues = new HashMap<>();
        contentValues.put("body", body);
        contentValues.put("time", etaText);

        NotificationCompat.Builder notification =
                new NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID)
                        .setSmallIcon(icon)
                        .setContentTitle(title)
                        .setContentText(NativeLocalization.text(context, "live_update.content", contentValues))
                        .setSubText(subText)
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

            if (actionId != null && actionLabel != null) {
                Intent actionIntent = new Intent(launchIntent)
                        .putExtra(EXTRA_ACTION, actionId)
                        .putExtra(EXTRA_ACTION_ARGUMENT, actionArgument);
                // A different request code from the content intent: intents
                // that differ only in extras would otherwise share one.
                PendingIntent actionPendingIntent = PendingIntent.getActivity(
                        context,
                        ~id,
                        actionIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
                notification.addAction(0, actionLabel, actionPendingIntent);
            }
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
                NativeLocalization.text(context, "notification.channel.updates"),
                NotificationManager.IMPORTANCE_DEFAULT);
        channel.setDescription(NativeLocalization.text(
                context, "notification.channel.updates.description"));
        channel.setSound(null, null);
        channel.enableVibration(false);
        manager.createNotificationChannel(channel);
    }

    /** Reads a countdown action from [intent], once. */
    private Map<String, Object> takeAction(Intent intent) {
        if (intent == null || !intent.hasExtra(EXTRA_ACTION)) return null;
        Map<String, Object> action = new HashMap<>();
        action.put("actionId", intent.getStringExtra(EXTRA_ACTION));
        action.put("argument", intent.getStringExtra(EXTRA_ACTION_ARGUMENT));
        // So the activity being recreated, such as on rotation, doesn't
        // repeat it.
        intent.removeExtra(EXTRA_ACTION);
        intent.removeExtra(EXTRA_ACTION_ARGUMENT);
        return action;
    }

    @Override
    public boolean onNewIntent(@NonNull Intent intent) {
        Map<String, Object> action = takeAction(intent);
        if (action == null) return false;
        if (channel != null) {
            channel.invokeMethod("onAction", action);
        } else {
            pendingAction = action;
        }
        return true;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activityBinding = binding;
        binding.addOnNewIntentListener(this);
        Map<String, Object> action = takeAction(binding.getActivity().getIntent());
        if (action != null) pendingAction = action;
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activityBinding != null) activityBinding.removeOnNewIntentListener(this);
        activityBinding = null;
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
        context = null;
    }
}

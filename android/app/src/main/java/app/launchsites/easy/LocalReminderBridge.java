package app.launchsites.easy;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public final class LocalReminderBridge implements MethodChannel.MethodCallHandler {
    private static final int NOTIFICATION_PERMISSION = 4206;
    private static final String ASKED = "notificationPermissionRequested";

    private final Activity activity;
    private final MethodChannel channel;
    private MethodChannel.Result permissionResult;

    public LocalReminderBridge(Activity activity, BinaryMessenger messenger) {
        this.activity = activity;
        channel = new MethodChannel(messenger, "app.launchsites.easy/local_reminders");
        channel.setMethodCallHandler(this);
    }

    public void detach() {
        channel.setMethodCallHandler(null);
        if (permissionResult != null) {
            permissionResult.error("permission_interrupted", "Notification request ended.", null);
            permissionResult = null;
        }
    }

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "authorization":
                    result.success(capabilities());
                    break;
                case "requestNotifications":
                    requestNotifications(result);
                    break;
                case "requestExactScheduling":
                    requestExactScheduling(result);
                    break;
                case "pending":
                    List<Map<String, Object>> pending = new ArrayList<>();
                    for (LocalReminderAlarms.Request request : LocalReminderAlarms.pending(activity)) {
                        Map<String, Object> data = request.toMap();
                        data.put("armed", LocalReminderAlarms.isArmed(activity, request.id));
                        pending.add(data);
                    }
                    result.success(pending);
                    break;
                case "schedule":
                    LocalReminderAlarms.schedule(activity, LocalReminderAlarms.Request.fromChannel(call.arguments));
                    result.success(null);
                    break;
                case "cancel":
                    if (!(call.arguments instanceof List<?>)) {
                        result.error("invalid_reminder", "Invalid reminder identifiers.", null);
                        return;
                    }
                    List<String> canceled = new ArrayList<>();
                    for (Object value : (List<?>) call.arguments) {
                        if (!(value instanceof String) || !LocalReminderAlarms.isOwned((String) value)) {
                            result.error("invalid_reminder", "Invalid reminder identifiers.", null);
                            return;
                        }
                        canceled.add((String) value);
                    }
                    LocalReminderAlarms.cancel(activity, canceled);
                    result.success(null);
                    break;
                default:
                    result.notImplemented();
            }
        } catch (IllegalArgumentException exception) {
            result.error("invalid_reminder", "Choose a valid future reminder.", null);
        } catch (RuntimeException exception) {
            result.error("reminder_unavailable", "Local reminders could not be updated.", null);
        }
    }

    private Map<String, Object> capabilities() {
        final boolean exact = LocalReminderAlarms.exactAllowed(activity);
        final String permission;
        if (LocalReminderAlarms.notificationsAllowed(activity)) {
            permission = "granted";
        } else if (Build.VERSION.SDK_INT >= 33
                && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                        != PackageManager.PERMISSION_GRANTED
                && !LocalReminderAlarms.preferences(activity).getBoolean(ASKED, false)) {
            permission = "notDetermined";
        } else {
            permission = "denied";
        }
        Map<String, Object> result = new HashMap<>();
        result.put("permission", permission);
        result.put("exactScheduling", exact);
        result.put("canRequestExactScheduling", Build.VERSION.SDK_INT >= 31 && !exact);
        return result;
    }

    private void requestNotifications(MethodChannel.Result result) {
        if (Build.VERSION.SDK_INT < 33
                || activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                        == PackageManager.PERMISSION_GRANTED) {
            result.success(capabilities());
            return;
        }
        if (permissionResult != null) {
            result.error("permission_pending", "A notification request is already open.", null);
            return;
        }
        permissionResult = result;
        try {
            activity.requestPermissions(
                    new String[] { Manifest.permission.POST_NOTIFICATIONS }, NOTIFICATION_PERMISSION);
        } catch (RuntimeException exception) {
            permissionResult = null;
            result.error("permission_failed", "Could not request notification permission.", null);
        }
    }

    public void completePermissionRequest(int requestCode, int[] grantResults) {
        if (requestCode != NOTIFICATION_PERMISSION || permissionResult == null) return;
        final MethodChannel.Result result = permissionResult;
        permissionResult = null;
        if (grantResults.length != 0) {
            LocalReminderAlarms.preferences(activity).edit().putBoolean(ASKED, true).apply();
        }
        result.success(capabilities());
    }

    private void requestExactScheduling(MethodChannel.Result result) {
        if (Build.VERSION.SDK_INT >= 31 && !LocalReminderAlarms.exactAllowed(activity)) {
            Intent intent = new Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM);
            intent.setData(Uri.fromParts("package", activity.getPackageName(), null));
            activity.startActivity(intent);
        }
        result.success(null);
    }
}

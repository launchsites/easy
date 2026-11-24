package app.launchsites.easy;

import android.Manifest;
import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import org.json.JSONException;
import org.json.JSONObject;

final class LocalReminderAlarms {
    static final String DELIVER = "app.launchsites.easy.DELIVER_LOCAL_REMINDER";
    private static final String CHANNEL = "easy_local_reminders";
    private static final Pattern ID = Pattern.compile("easy-local-reminder-[a-f0-9]{64}");
    private static final long HORIZON_MILLIS = 31L * 24 * 60 * 60 * 1000;

    private LocalReminderAlarms() {}

    static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences("easy_local_reminder_alarms", Context.MODE_PRIVATE);
    }

    static boolean isOwned(String id) {
        return id != null && ID.matcher(id).matches();
    }

    static boolean exactAllowed(Context context) {
        AlarmManager available = context.getSystemService(AlarmManager.class);
        return available != null &&
                (Build.VERSION.SDK_INT < 31 || available.canScheduleExactAlarms());
    }

    static boolean isArmed(Context context, String id) {
        return PendingIntent.getBroadcast(context, 0, intent(context, id),
                PendingIntent.FLAG_NO_CREATE | PendingIntent.FLAG_IMMUTABLE) != null;
    }

    static boolean notificationsAllowed(Context context) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) return false;
        if (Build.VERSION.SDK_INT >= 33 &&
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                        != PackageManager.PERMISSION_GRANTED) return false;
        if (!manager.areNotificationsEnabled()) return false;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = manager.getNotificationChannel(CHANNEL);
            return channel == null || channel.getImportance() != NotificationManager.IMPORTANCE_NONE;
        }
        return true;
    }

    static List<Request> pending(Context context) {
        List<Request> found = new ArrayList<>();
        for (Map.Entry<String, ?> entry : preferences(context).getAll().entrySet()) {
            if (!isOwned(entry.getKey()) || !(entry.getValue() instanceof String)) continue;
            Request request = Request.fromStored(entry.getKey(), (String) entry.getValue());
            if (request != null) found.add(request);
        }
        return found;
    }

    static void schedule(Context context, Request request) {
        long delay = request.at - System.currentTimeMillis();
        if (delay <= 0 || delay > HORIZON_MILLIS) throw new IllegalArgumentException();
        if (!exactAllowed(context) || !notificationsAllowed(context)) {
            throw new IllegalStateException();
        }
        SharedPreferences stored = preferences(context);
        final String previous = stored.getString(request.id, null);
        if (!stored.edit().putString(request.id, request.toStored()).commit()) {
            throw new IllegalStateException();
        }
        try {
            arm(context, request);
        } catch (RuntimeException failure) {
            if (!stored.edit().putString(request.id, previous).commit()) {
                failure.addSuppressed(new IllegalStateException("Could not restore reminder state"));
            }
            throw failure;
        }
    }

    static void cancel(Context context, List<String> ids) {
        final SharedPreferences.Editor removal = preferences(context).edit();
        for (String id : ids) removal.remove(id);
        if (!removal.commit()) throw new IllegalStateException();
        final AlarmManager manager = context.getSystemService(AlarmManager.class);
        if (manager == null) return;
        for (String id : ids) {
            PendingIntent pending = PendingIntent.getBroadcast(
                    context, 0, intent(context, id), PendingIntent.FLAG_NO_CREATE | PendingIntent.FLAG_IMMUTABLE);
            if (pending != null) {
                manager.cancel(pending);
                pending.cancel();
            }
        }
    }

    static void restore(Context context) {
        final long now = System.currentTimeMillis();
        final List<String> stale = new ArrayList<>();
        final boolean authorized = exactAllowed(context) && notificationsAllowed(context);
        for (Request request : pending(context)) {
            if (request.at <= now || request.at - now > HORIZON_MILLIS) {
                stale.add(request.id);
            } else if (authorized) {
                try {
                    arm(context, request);
                } catch (RuntimeException ignored) {
                    // Access can change between validation and the OS call.
                }
            }
        }
        if (!stale.isEmpty()) cancel(context, stale);
    }

    static void deliver(Context context, String id) {
        if (!isOwned(id)) return;
        final SharedPreferences stored = preferences(context);
        final Request request = Request.fromStored(id, stored.getString(id, null));
        if (request == null) return;
        if (request.at > System.currentTimeMillis()) return;
        if (!stored.edit().remove(id).commit() || !notificationsAllowed(context)) return;

        final NotificationManager manager = context.getSystemService(NotificationManager.class);
        final Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        final PendingIntent target = launch == null ? null : PendingIntent.getActivity(
                context, 0, launch, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);

        final Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(new NotificationChannel(
                    CHANNEL, "Reminders", NotificationManager.IMPORTANCE_DEFAULT));
            builder = new Notification.Builder(context, CHANNEL);
        } else {
            builder = new Notification.Builder(context);
            builder.setDefaults(Notification.DEFAULT_SOUND);
        }
        builder.setSmallIcon(android.R.drawable.ic_popup_reminder)
                .setContentTitle(request.title)
                .setContentText(request.body)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setAutoCancel(true);
        if (target != null) builder.setContentIntent(target);
        manager.notify(id, 0, builder.build());
    }

    private static void arm(Context context, Request request) {
        final AlarmManager manager = context.getSystemService(AlarmManager.class);
        if (manager == null) throw new IllegalStateException();
        final PendingIntent pending = PendingIntent.getBroadcast(
                context, 0, intent(context, request.id),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, request.at, pending);
    }

    private static Intent intent(Context context, String id) {
        return new Intent(context, LocalReminderReceiver.class).setAction(DELIVER)
                .setData(Uri.parse("easy-reminder://alarm/" + id));
    }

    static final class Request {
        final String id;
        final long at;
        final String title;
        final String body;

        Request(String id, long at, String title, String body) {
            if (!isOwned(id) || at <= 0 || title == null || title.trim().isEmpty() || title.length() > 320
                    || body == null || body.trim().isEmpty() || body.length() > 320) {
                throw new IllegalArgumentException();
            }
            this.id = id;
            this.at = at;
            this.title = title;
            this.body = body;
        }

        static Request fromChannel(Object value) {
            if (!(value instanceof Map<?, ?>)) throw new IllegalArgumentException();
            final Map<?, ?> map = (Map<?, ?>) value;
            final Object time = map.get("atMilliseconds");
            if (!(map.get("id") instanceof String) || !(time instanceof Number) ||
                    !(map.get("title") instanceof String) || !(map.get("body") instanceof String)) {
                throw new IllegalArgumentException();
            }
            return new Request((String) map.get("id"), ((Number) time).longValue(),
                    (String) map.get("title"), (String) map.get("body"));
        }

        static Request fromStored(String id, String value) {
            if (value == null) return null;
            try {
                final JSONObject row = new JSONObject(value);
                return new Request(id, row.getLong("at"), row.getString("title"), row.getString("body"));
            } catch (JSONException | IllegalArgumentException invalid) {
                return null;
            }
        }

        String toStored() {
            try {
                return new JSONObject().put("at", at).put("title", title).put("body", body).toString();
            } catch (JSONException invalid) {
                throw new IllegalArgumentException(invalid);
            }
        }

        Map<String, Object> toMap() {
            final Map<String, Object> value = new HashMap<>();
            value.put("id", id);
            value.put("atMilliseconds", at);
            value.put("title", title);
            value.put("body", body);
            return value;
        }
    }
}

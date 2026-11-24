package app.launchsites.easy;

import android.app.AlarmManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

public final class LocalReminderReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        final String action = intent.getAction();
        try {
            if (LocalReminderAlarms.DELIVER.equals(action)) {
                final Uri location = intent.getData();
                if (location != null) LocalReminderAlarms.deliver(context, location.getLastPathSegment());
            } else if (Intent.ACTION_BOOT_COMPLETED.equals(action) ||
                    AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED.equals(action)) {
                LocalReminderAlarms.restore(context);
            }
        } catch (RuntimeException ignored) {
            // Permission or storage changes are reconciled when Easy next opens.
        }
    }
}

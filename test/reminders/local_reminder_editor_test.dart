import 'package:easy/reminders/local_reminder.dart';
import 'package:easy/reminders/local_reminder_backend.dart';
import 'package:easy/reminders/local_reminder_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'local_reminder_test.dart' show MemoryReminderBackend;

void main() {
  testWidgets(
    'device settings only prompt from explicit action then save opt-in',
    (tester) async {
      final backend = MemoryReminderBackend()
        ..capabilities = const LocalReminderCapabilities(
          permission: LocalReminderPermission.notDetermined,
          exactScheduling: true,
        );
      LocalReminderSettings? saved;
      await tester.pumpWidget(
        _host((context) async {
          saved = await showLocalReminderSettings(
            context,
            settings: const LocalReminderSettings(),
            backend: backend,
          );
        }),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(backend.permissionPrompts, 0);
      expect(saved, isNull);
      await tester.tap(find.text('Allow notifications'));
      await tester.pumpAndSettle();
      expect(backend.permissionPrompts, 1);
      expect(saved, isNull);
      await tester.tap(find.text('Deliver reminders'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved?.enabled, isTrue);
      expect(saved?.showRecordTitles, isFalse);
    },
  );

  testWidgets(
    'precise alarms open only when the user chooses the permission action',
    (tester) async {
      final backend = MemoryReminderBackend()
        ..capabilities = const LocalReminderCapabilities(
          permission: LocalReminderPermission.granted,
          exactScheduling: false,
          canRequestExactScheduling: true,
        );
      await tester.pumpWidget(
        _host(
          (context) => showLocalReminderSettings(
            context,
            settings: const LocalReminderSettings(),
            backend: backend,
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(backend.exactPrompts, 0);
      final option = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Deliver reminders'),
      );
      expect(option.onChanged, isNull);
      await tester.tap(find.text('Allow precise alarms'));
      await tester.pumpAndSettle();
      expect(backend.exactPrompts, 1);
      expect(backend.permissionPrompts, 0);
    },
  );

  testWidgets(
    'record editor returns a reviewed lead time without delivering a notification',
    (tester) async {
      RecordReminderChoice? choice;
      final target = ReminderTarget(
        kind: ReminderTargetKind.plannedBlock,
        recordId: 'block',
      );
      final start = DateTime.now().add(const Duration(days: 1));
      await tester.pumpWidget(
        _host((context) async {
          choice = await showRecordReminderEditor(
            context,
            target: target,
            start: start,
          );
        }),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Before the start'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '25');
      expect(choice, isNull);
      await tester.tap(find.text('Save reminder'));
      await tester.pumpAndSettle();
      expect(choice?.preference?.minutesBeforeStart, 25);
      expect(choice?.preference?.target.notificationId, target.notificationId);
    },
  );
}

Widget _host(void Function(BuildContext) open) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => open(context),
        child: const Text('Open'),
      ),
    ),
  ),
);

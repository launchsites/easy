import 'package:material_ui/material_ui.dart';

import 'gym_session.dart';
import 'ui_theme.dart';

class GymHistoryPage extends StatelessWidget {
  const GymHistoryPage({
    required this.sessions,
    required this.onOpen,
    super.key,
  });

  final List<GymSession> sessions;
  final ValueChanged<GymSession> onOpen;

  @override
  Widget build(BuildContext context) {
    final records = sessions.where((session) => session.finished).toList()
      ..sort((first, second) => second.startedAt.compareTo(first.startedAt));
    final labels = MaterialLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Workout history')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 670),
            child: records.isEmpty
                ? const Text(
                    'No workout entries yet.',
                    style: contentMetadataStyle,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(22, 10, 22, 30),
                    itemCount: records.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, index) {
                      final session = records[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 5,
                        ),
                        title: Text(
                          session.planned || session.exercises.isNotEmpty
                              ? session.workoutTitle
                              : session.entries.firstOrNull?.title ??
                                    session.workoutTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          labels.formatFullDate(session.startedAt.toLocal()),
                          style: contentMetadataStyle,
                        ),
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          color: muted,
                        ),
                        onTap: () => onOpen(session),
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

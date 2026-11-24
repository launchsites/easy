import '../task_model.dart';

final _exerciseAction = RegExp(
  r'^\s*(?:go\s+for\s+(?:a\s+)?(?:run|jog)|(?:do|start|finish)\s+(?:my\s+|the\s+)?(?:workout|gym session)|go\s+to\s+(?:the\s+)?gym)(?:\s|[.!]|$)',
  caseSensitive: false,
);
final _schoolTask = RegExp(
  r'\b(?:homework|coursework)\b|^\s*(?:revise|study)\s+for\s+(?:the\s+|my\s+)?(?:exam|test)',
  caseSensitive: false,
);
final _workTask = RegExp(
  r'^\s*(?:find\s+(?:new\s+)?(?:website|client)\s+leads|(?:make|draft|finish|write)\s+(?:a\s+|the\s+|my\s+)?(?:social\s+media|content)\s+plan)(?:\s|[.!]|$)',
  caseSensitive: false,
);

/// High-signal defaults for a title. Manual category choices take precedence.
String? taskCategoryHint(String title, Iterable<String> allowed) {
  final category = switch (title) {
    _ when _familyAppointment.hasMatch(title) => 'personal',
    _ when _exerciseAction.hasMatch(title) => 'gym',
    _ when _schoolTask.hasMatch(title) => 'study',
    _ when _workTask.hasMatch(title) => 'work',
    _ => null,
  };
  return category != null && allowed.contains(category) ? category : null;
}

final _familyAppointment = RegExp(
  r'^\s*(?:take|drive|bring|pick\s+up|drop\s+off)\s+my\s+'
  r'(?:sister|brother|son|daughter|mum|mom|dad|parent|cousin|partner|child|kid)'
  r'\s+(?:to|from|at)\s+(?:(?:the|an?|their|her|his)\s+)?'
  r'(?:(?:football|basketball|hockey|soccer|school|medical)\s+)?'
  r'(?:game|match|practice|appointment|rehearsal|lesson)\b',
  caseSensitive: false,
);

TaskSchedulingHold? taskSchedulingHoldHint(String title) =>
    _familyAppointment.hasMatch(title)
    ? const TaskSchedulingHold(reason: TaskSchedulingHoldReason.appointmentTime)
    : null;

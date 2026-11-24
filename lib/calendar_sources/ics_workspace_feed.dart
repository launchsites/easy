import 'calendar_window_feed.dart';
import 'ics_workspace.dart';

class IcsWorkspaceFeed
    extends CalendarWindowFeed<WorkspaceIcsCalendar, IcsWorkspaceEvent> {
  IcsWorkspaceFeed()
    : super(
        expand: _expand,
        errorMessage:
            'Imported calendars could not be displayed for these dates.',
      );
}

List<IcsWorkspaceEvent> _expand(
  CalendarWindowInput<WorkspaceIcsCalendar> input,
) => expandWorkspaceIcs((
  calendars: input.sources,
  start: input.start,
  end: input.end,
));

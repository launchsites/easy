enum TaskCapturePlacement {
  today('Today'),
  tomorrow('Tomorrow'),
  inbox('Inbox');

  const TaskCapturePlacement(this.label);
  final String label;
}

final class TaskCaptureDefaults {
  const TaskCaptureDefaults({
    this.placement = TaskCapturePlacement.inbox,
    this.categoryId,
  });

  factory TaskCaptureDefaults.fromJson(Map<String, dynamic> json) {
    final placementName = json['placement'];
    final category = json['categoryId'];
    final version = json['version'];
    if (version is! int ||
        version != 1 ||
        placementName is! String ||
        (category != null && category is! String)) {
      throw const FormatException('Invalid task capture defaults.');
    }
    final placement = TaskCapturePlacement.values.asNameMap()[placementName];
    if (placement == null) {
      throw const FormatException('Invalid task placement.');
    }
    return TaskCaptureDefaults(
      placement: placement,
      categoryId: category as String?,
    );
  }

  final TaskCapturePlacement placement;

  /// Null uses the focus mode preference. An empty string selects General.
  final String? categoryId;

  DateTime? dateFor(DateTime at) {
    final local = at.toLocal();
    return switch (placement) {
      TaskCapturePlacement.today => DateTime(
        local.year,
        local.month,
        local.day,
      ),
      TaskCapturePlacement.tomorrow => DateTime(
        local.year,
        local.month,
        local.day + 1,
      ),
      TaskCapturePlacement.inbox => null,
    };
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'placement': placement.name,
    'categoryId': ?categoryId,
  };
}

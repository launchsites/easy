import 'dart:convert';

import 'package:easy/focus/focus_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('several views may include the same record category', () {
    final gym = standardFocusModes().firstWhere((mode) => mode.id == 'gym');
    final health = FocusMode(
      id: 'health',
      name: 'Health',
      color: 0xff427854,
      categories: {'health', 'gym'},
      preferredCategory: 'personal',
    );
    expect(gym.includes('gym'), isTrue);
    expect(health.includes('gym'), isTrue);
    expect(health.includes('personal'), isFalse);
    expect(health.preferredCategory, 'personal');
  });

  test('mode filters and sections round trip independently', () {
    final mode = FocusMode(
      id: 'planning',
      name: 'Planning',
      color: 0xff775d96,
      categories: {'work', 'study'},
      sections: {FocusSection.tasks},
    );
    final restored = FocusMode.fromJson(
      jsonDecode(jsonEncode(mode.toJson())) as Map<String, dynamic>,
    );
    expect(restored.toJson(), mode.toJson());
    expect(() => restored.categories!.add('personal'), throwsUnsupportedError);
    expect(restored.includes(null), isFalse);
  });

  test('all, none, and unknown future sections remain display decisions', () {
    final all = FocusMode(id: 'all', name: 'All', color: 0xff000000);
    final empty = FocusMode.fromJson({
      'id': 'quiet',
      'name': 'Quiet',
      'color': 0xff000000,
      'categories': <String>[],
      'sections': ['later-version-feature'],
    });
    expect(all.includes(null), isTrue);
    expect(all.includes('any category'), isTrue);
    expect(empty.includes('any category'), isFalse);
    expect(empty.sections, isEmpty);
  });
}

/// Builds a response format exclusively from fields the capture already sends.
/// The provider's grammar narrows structure. Local validation still handles
/// clause-specific permissions, duplicates, source changes and review.
Map<String, Object?> captureJsonSchemaResponseFormat(
  Map<String, Object?> fields,
) {
  final clauses = (fields['clauses'] as List).cast<Map<String, Object?>>();
  if (clauses.isEmpty) {
    throw const FormatException('No capture clauses are available.');
  }
  final categories = (fields['categoryIds'] as Map).keys.cast<String>();
  final kinds = {
    for (final clause in clauses) ...(clause['choices'] as List).cast<String>(),
  };
  return {
    'type': 'json_schema',
    'json_schema': {
      'name': 'capture_suggestions',
      'strict': true,
      'schema': _object({
        'version': _enum([2]),
        'captureId': _enum([fields['captureId']]),
        'sourceRevision': _enum([fields['sourceRevision']]),
        'contextRevision': _enum([fields['contextRevision']]),
        'suggestions': {
          'type': 'array',
          'maxItems': clauses.length,
          'items': _object({
            'clause': _enum([for (final clause in clauses) clause['clause']]),
            'kind': _enum(kinds.toList()),
            'category': _enum([...categories, null]),
          }),
        },
      }),
    },
  };
}

Map<String, Object?> _object(Map<String, Object?> properties) => {
  'type': 'object',
  'properties': properties,
  'required': properties.keys.toList(),
  'additionalProperties': false,
};

Map<String, Object?> _enum(List<Object?> choices) => {'enum': choices};

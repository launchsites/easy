import '../ai_budget.dart';

enum AiTokenLimitField { maxTokens, maxCompletionTokens }

/// Stores an opaque vault reference with provider settings.
abstract interface class AiCredentialVault {
  Future<String?> read(String reference);
}

class AiProviderConfig {
  const AiProviderConfig.paid({
    required this.baseUri,
    required this.model,
    required String this.credentialRef,
    required AiPrice this.price,
    required this.maxInputTokens,
    required this.maxOutputTokens,
    this.allowEstimates = false,
    this.jsonObjectMode = true,
    this.tokenLimitField = AiTokenLimitField.maxCompletionTokens,
  }) : execution = AiExecution.paidApi;

  const AiProviderConfig.loopback({
    required this.baseUri,
    required this.model,
    required this.maxInputTokens,
    required this.maxOutputTokens,
    this.allowEstimates = false,
    this.jsonObjectMode = false,
    this.tokenLimitField = AiTokenLimitField.maxTokens,
  }) : execution = AiExecution.local,
       credentialRef = null,
       price = null;

  final AiExecution execution;
  final Uri baseUri;
  final String model;
  final String? credentialRef;
  final AiPrice? price;
  final int maxInputTokens;
  final int maxOutputTokens;
  final bool allowEstimates;
  final bool jsonObjectMode;
  final AiTokenLimitField tokenLimitField;

  AiBudgetRequest budgetRequest(String id, {required AiWorkKind work}) =>
      AiBudgetRequest(
        id: id,
        maxInputTokens: maxInputTokens,
        maxOutputTokens: maxOutputTokens,
        price: price,
        execution: execution,
        work: work,
      );

  /// The only endpoint generated from this configuration.
  Uri? get completionsEndpoint {
    final uri = baseUri;
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535)) ||
        !_modelName.hasMatch(model) ||
        maxInputTokens < 1 ||
        maxInputTokens > aiMaxExactInteger ||
        maxOutputTokens < 1 ||
        maxOutputTokens > aiMaxExactInteger) {
      return null;
    }
    switch (execution) {
      case AiExecution.paidApi:
        if (uri.scheme != 'https' ||
            price?.valid != true ||
            !_vaultReference.hasMatch(credentialRef ?? '')) {
          return null;
        }
      case AiExecution.local:
        if (uri.scheme != 'http' ||
            !const {'127.0.0.1', '::1'}.contains(uri.host)) {
          return null;
        }
    }
    final path = uri.pathSegments.toList();
    if (path.isNotEmpty && path.last.isEmpty) {
      path.removeLast();
    }
    if (path.any(
      (segment) =>
          segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          _ambiguousPath.hasMatch(segment),
    )) {
      return null;
    }
    return uri.replace(pathSegments: [...path, 'chat', 'completions']);
  }

  String get tokenLimitProperty => switch (tokenLimitField) {
    AiTokenLimitField.maxTokens => 'max_tokens',
    AiTokenLimitField.maxCompletionTokens => 'max_completion_tokens',
  };
}

final _modelName = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,199}$');
final _vaultReference = RegExp(r'^[a-zA-Z0-9._:-]{1,160}$');
final _ambiguousPath = RegExp(r'[/\\?#\x00-\x1f\x7f]');

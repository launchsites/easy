import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'ai_budget.dart';
import 'provider/ai_provider.dart';

enum AiRoute { offline, local, api }

abstract interface class AiWritableCredentialVault
    implements AiCredentialVault {
  bool get persistent;
  Future<void> write(String reference, String secret);
  Future<void> delete(String reference);
}

/// Host adapters can connect this interface to the operating system vault.
class AiCallbackCredentialVault implements AiWritableCredentialVault {
  const AiCallbackCredentialVault({
    required this.readSecret,
    required this.writeSecret,
    required this.deleteSecret,
  });

  final Future<String?> Function(String reference) readSecret;
  final Future<void> Function(String reference, String secret) writeSecret;
  final Future<void> Function(String reference) deleteSecret;

  @override
  bool get persistent => true;

  @override
  Future<String?> read(String reference) => readSecret(reference);

  @override
  Future<void> write(String reference, String secret) =>
      writeSecret(reference, secret);

  @override
  Future<void> delete(String reference) => deleteSecret(reference);
}

class AiSessionCredentialVault implements AiWritableCredentialVault {
  final _keys = <String, String>{};

  @override
  bool get persistent => false;

  @override
  Future<String?> read(String reference) async => _keys[reference];

  @override
  Future<void> write(String reference, String secret) async {
    _keys[reference] = secret;
  }

  @override
  Future<void> delete(String reference) async {
    _keys.remove(reference);
  }
}

class AiRuntimeSettings {
  const AiRuntimeSettings({
    this.route = AiRoute.offline,
    this.apiBaseUrl = '',
    this.apiModel = '',
    this.localBaseUrl = 'http://127.0.0.1:11434/v1',
    this.localModel = '',
    this.monthlyCapMicros = 0,
    this.inputMicrosPerMillion,
    this.outputMicrosPerMillion,
    this.maxInputTokens = 8192,
    this.maxOutputTokens = 512,
    this.includeOptionalMetadata = false,
    this.confirmLocal = true,
    this.allowEstimates = false,
    this.apiUsesCompletionTokenLimit = true,
  });

  final AiRoute route;
  final String apiBaseUrl;
  final String apiModel;
  final String localBaseUrl;
  final String localModel;
  final int monthlyCapMicros;
  final int? inputMicrosPerMillion;
  final int? outputMicrosPerMillion;
  final int maxInputTokens;
  final int maxOutputTokens;
  final bool includeOptionalMetadata;
  final bool confirmLocal;
  final bool allowEstimates;
  final bool apiUsesCompletionTokenLimit;

  bool get valid =>
      _nonnegative(monthlyCapMicros) &&
      (inputMicrosPerMillion == null || _nonnegative(inputMicrosPerMillion!)) &&
      (outputMicrosPerMillion == null ||
          _nonnegative(outputMicrosPerMillion!)) &&
      maxInputTokens > 0 &&
      _nonnegative(maxInputTokens) &&
      maxOutputTokens > 0 &&
      _nonnegative(maxOutputTokens) &&
      (apiBaseUrl.trim().isEmpty || _apiAddress != null) &&
      (localBaseUrl.trim().isEmpty || _localAddress != null) &&
      (route == AiRoute.offline || provider != null);

  AiProviderConfig? get provider => switch (route) {
    AiRoute.offline => null,
    AiRoute.local => _localProvider,
    AiRoute.api => _apiProvider,
  };

  /// Opaque reference scoped to the original endpoint. A changed URL requires
  /// its own vault entry.
  String? get apiCredentialReference {
    final address = _apiAddress;
    if (address == null) return null;
    return 'easy.ai.${sha256.convert(utf8.encode(address.toString()))}';
  }

  Uri? get _apiAddress {
    final uri = Uri.tryParse(apiBaseUrl.trim());
    if (uri == null) return null;
    return AiProviderConfig.paid(
      baseUri: uri,
      model: 'route-check',
      credentialRef: 'route-check',
      price: const AiPrice(
        currency: 'GBP',
        inputMicrosPerMillion: 0,
        outputMicrosPerMillion: 0,
      ),
      maxInputTokens: 1,
      maxOutputTokens: 1,
    ).completionsEndpoint;
  }

  Uri? get _localAddress {
    final uri = Uri.tryParse(localBaseUrl.trim());
    if (uri == null) return null;
    return AiProviderConfig.loopback(
      baseUri: uri,
      model: 'route-check',
      maxInputTokens: 1,
      maxOutputTokens: 1,
    ).completionsEndpoint;
  }

  AiProviderConfig? get _apiProvider {
    final uri = Uri.tryParse(apiBaseUrl.trim());
    final reference = apiCredentialReference;
    final input = inputMicrosPerMillion;
    final output = outputMicrosPerMillion;
    if (uri == null || reference == null || input == null || output == null) {
      return null;
    }
    final config = AiProviderConfig.paid(
      baseUri: uri,
      model: apiModel.trim(),
      credentialRef: reference,
      price: AiPrice(
        currency: 'GBP',
        inputMicrosPerMillion: input,
        outputMicrosPerMillion: output,
      ),
      maxInputTokens: maxInputTokens,
      maxOutputTokens: maxOutputTokens,
      allowEstimates: allowEstimates,
      tokenLimitField: apiUsesCompletionTokenLimit
          ? AiTokenLimitField.maxCompletionTokens
          : AiTokenLimitField.maxTokens,
    );
    return config.completionsEndpoint == null ? null : config;
  }

  AiProviderConfig? get _localProvider {
    final uri = Uri.tryParse(localBaseUrl.trim());
    if (uri == null) return null;
    final config = AiProviderConfig.loopback(
      baseUri: uri,
      model: localModel.trim(),
      maxInputTokens: maxInputTokens,
      maxOutputTokens: maxOutputTokens,
      allowEstimates: allowEstimates,
    );
    return config.completionsEndpoint == null ? null : config;
  }

  Map<String, Object?> toJson() => {
    'route': route.name,
    'apiBaseUrl': apiBaseUrl.trim(),
    'apiModel': apiModel.trim(),
    'localBaseUrl': localBaseUrl.trim(),
    'localModel': localModel.trim(),
    'monthlyCapMicros': monthlyCapMicros,
    'inputMicrosPerMillion': inputMicrosPerMillion,
    'outputMicrosPerMillion': outputMicrosPerMillion,
    'maxInputTokens': maxInputTokens,
    'maxOutputTokens': maxOutputTokens,
    'includeOptionalMetadata': includeOptionalMetadata,
    'confirmLocal': confirmLocal,
    'allowEstimates': allowEstimates,
    'apiUsesCompletionTokenLimit': apiUsesCompletionTokenLimit,
  };

  factory AiRuntimeSettings.fromJson(Map<String, dynamic> values) =>
      AiRuntimeSettings(
        route: AiRoute.values.byName(values['route'] as String),
        apiBaseUrl: values['apiBaseUrl'] as String,
        apiModel: values['apiModel'] as String,
        localBaseUrl: values['localBaseUrl'] as String,
        localModel: values['localModel'] as String,
        monthlyCapMicros: values['monthlyCapMicros'] as int,
        inputMicrosPerMillion: values['inputMicrosPerMillion'] as int?,
        outputMicrosPerMillion: values['outputMicrosPerMillion'] as int?,
        maxInputTokens: values['maxInputTokens'] as int,
        maxOutputTokens: values['maxOutputTokens'] as int,
        includeOptionalMetadata: values['includeOptionalMetadata'] as bool,
        confirmLocal: values['confirmLocal'] as bool,
        allowEstimates: values['allowEstimates'] as bool,
        apiUsesCompletionTokenLimit:
            values['apiUsesCompletionTokenLimit'] as bool,
      );
}

bool _nonnegative(int value) => value >= 0 && value <= aiMaxExactInteger;

bool validAiKey(String value) =>
    value.isNotEmpty &&
    value.length <= 4096 &&
    value.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);

int? parsePoundsMicros(String text) {
  var value = text.trim();
  if (value.startsWith('£')) value = value.substring(1).trim();
  final pieces = value.split('.');
  if (pieces.length > 2) return null;
  final whole = pieces[0];
  final fraction = pieces.length == 2 ? pieces[1] : '';
  if ((!_poundsDigits.hasMatch(whole) &&
          !(whole.isEmpty && fraction.isNotEmpty)) ||
      !_microsDigits.hasMatch(fraction)) {
    return null;
  }
  final micros =
      BigInt.parse(whole.isEmpty ? '0' : whole.replaceAll(',', '')) *
          BigInt.from(1000000) +
      BigInt.parse(fraction.padRight(6, '0'));
  return micros <= BigInt.from(aiMaxExactInteger) ? micros.toInt() : null;
}

String formatPoundsMicros(int micros) {
  final pounds = micros ~/ 1000000;
  var fraction = (micros % 1000000).toString().padLeft(6, '0');
  while (fraction.length > 2 && fraction.endsWith('0')) {
    fraction = fraction.substring(0, fraction.length - 1);
  }
  return '£$pounds.$fraction';
}

final _poundsDigits = RegExp(r'^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)$');
final _microsDigits = RegExp(r'^[0-9]{0,6}$');

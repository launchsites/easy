import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'ai_runtime.dart';

Future<bool> showAiTransmissionDialog(
  BuildContext context,
  AiTransmissionPreview preview,
) async {
  final paid = preview.route == AiRoute.api;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(paid ? 'Send to API?' : 'Send to local runtime?'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(preview.endpoint.toString()),
              const SizedBox(height: 4),
              Text(preview.model, style: const TextStyle(color: muted)),
              if (preview.reserveMicros case final reserve?) ...[
                const SizedBox(height: 9),
                Text('Reserve ${formatPoundsMicros(reserve)}'),
              ],
              const SizedBox(height: 16),
              const Text('Fields sent', style: sectionHeadingStyle),
              const SizedBox(height: 8),
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(preview.fields),
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Send'),
            ),
          ],
        ),
      ) ??
      false;
}

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({required this.runtime, super.key});

  final AiRuntime runtime;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final _apiUrl = TextEditingController();
  final _apiModel = TextEditingController();
  final _apiKey = TextEditingController();
  final _localUrl = TextEditingController();
  final _localModel = TextEditingController();
  final _cap = TextEditingController();
  final _inputRate = TextEditingController();
  final _outputRate = TextEditingController();
  final _inputTokens = TextEditingController();
  final _outputTokens = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _hasKey = false;
  AiRoute _route = AiRoute.offline;
  bool _metadata = false;
  bool _confirmLocal = true;
  bool _estimates = false;
  bool _completionTokens = true;
  String? _error;

  AiRuntime get _runtime => widget.runtime;

  @override
  void initState() {
    super.initState();
    _runtime.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    _runtime.removeListener(_changed);
    for (final field in [
      _apiUrl,
      _apiModel,
      _apiKey,
      _localUrl,
      _localModel,
      _cap,
      _inputRate,
      _outputRate,
      _inputTokens,
      _outputTokens,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool refresh = false}) async {
    final ok = await _runtime.load(refresh: refresh);
    final key = ok && await _runtime.hasApiKey();
    if (!mounted) return;
    final settings = _runtime.settings;
    setState(() {
      _loading = false;
      _route = settings.route;
      _metadata = settings.includeOptionalMetadata;
      _confirmLocal = settings.confirmLocal;
      _estimates = settings.allowEstimates;
      _completionTokens = settings.apiUsesCompletionTokenLimit;
      _apiUrl.text = settings.apiBaseUrl;
      _apiModel.text = settings.apiModel;
      _localUrl.text = settings.localBaseUrl;
      _localModel.text = settings.localModel;
      _cap.text = _poundsValue(settings.monthlyCapMicros);
      _inputRate.text = _poundsValue(settings.inputMicrosPerMillion);
      _outputRate.text = _poundsValue(settings.outputMicrosPerMillion);
      _inputTokens.text = '${settings.maxInputTokens}';
      _outputTokens.text = '${settings.maxOutputTokens}';
      _hasKey = key;
    });
  }

  String _poundsValue(int? micros) =>
      micros == null ? '' : formatPoundsMicros(micros).substring(1);

  void _selectRoute(AiRoute route) {
    setState(() {
      if (route != AiRoute.api) _apiKey.clear();
      _route = route;
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final prior = _runtime.settings;
    final paid = _route == AiRoute.api;
    final local = _route == AiRoute.local;
    final cap = parsePoundsMicros(_cap.text);
    final inputRate = paid
        ? parsePoundsMicros(_inputRate.text)
        : prior.inputMicrosPerMillion;
    final outputRate = paid
        ? parsePoundsMicros(_outputRate.text)
        : prior.outputMicrosPerMillion;
    final inputTokens = _route == AiRoute.offline
        ? prior.maxInputTokens
        : int.tryParse(_inputTokens.text.trim());
    final outputTokens = _route == AiRoute.offline
        ? prior.maxOutputTokens
        : int.tryParse(_outputTokens.text.trim());
    if (cap == null || (paid && (inputRate == null || outputRate == null))) {
      setState(
        () => _error = 'Enter valid pound amounts for the limit and rates.',
      );
      return;
    }
    if (inputTokens == null ||
        outputTokens == null ||
        inputTokens < 1 ||
        outputTokens < 1) {
      setState(() => _error = 'Enter positive token limits.');
      return;
    }
    final next = AiRuntimeSettings(
      route: _route,
      apiBaseUrl: paid ? _apiUrl.text.trim() : prior.apiBaseUrl,
      apiModel: paid ? _apiModel.text.trim() : prior.apiModel,
      localBaseUrl: local ? _localUrl.text.trim() : prior.localBaseUrl,
      localModel: local ? _localModel.text.trim() : prior.localModel,
      monthlyCapMicros: cap,
      inputMicrosPerMillion: inputRate,
      outputMicrosPerMillion: outputRate,
      maxInputTokens: inputTokens,
      maxOutputTokens: outputTokens,
      includeOptionalMetadata: _metadata,
      confirmLocal: _confirmLocal,
      allowEstimates: _estimates,
      apiUsesCompletionTokenLimit: _completionTokens,
    );
    setState(() {
      _saving = true;
      _error = null;
    });
    final key = paid && _apiKey.text.isNotEmpty ? _apiKey.text : null;
    final status = await _runtime.saveSettings(next, apiKey: key);
    if (!mounted) return;
    _apiKey.clear();
    final hasKey = await _runtime.hasApiKey();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _hasKey = hasKey;
      _error = switch (status) {
        AiSettingsSaveStatus.saved => null,
        AiSettingsSaveStatus.invalid =>
          'Check the endpoint, model, and request limits.',
        AiSettingsSaveStatus.busy => 'Finish the current review before saving.',
        AiSettingsSaveStatus.storageUnavailable =>
          'Reload AI settings before saving.',
        AiSettingsSaveStatus.vaultUnavailable =>
          'The selected vault could not save this key.',
      };
    });
    if (status == AiSettingsSaveStatus.saved) {
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('AI settings saved')));
    }
  }

  Future<void> _deleteKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove API key?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final removed = await _runtime.deleteApiKey();
    if (!mounted) return;
    setState(() {
      if (removed) _hasKey = false;
      _error = removed ? null : 'The key could not be removed.';
    });
  }

  Widget _money(TextEditingController field, String label) => TextField(
    controller: field,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: label, prefixText: '£ '),
  );

  Widget _usage() {
    final budget = _runtime.budget;
    final month = MaterialLocalizations.of(context)
        .formatMonthYear(DateTime(budget.month.year, budget.month.month));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: raisedPaper,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(month, style: sectionHeadingStyle),
            const SizedBox(height: 10),
            Wrap(
              spacing: 20,
              runSpacing: 12,
              children: [
                _usageValue('Used', budget.chargedMicros),
                _usageValue('Remaining', budget.remainingMicros),
                _usageValue('Forecast', budget.projectedMicros),
                if (budget.reservedMicros > 0)
                  _usageValue('Reserved', budget.reservedMicros),
              ],
            ),
            if (budget.unknownUsageCalls > 0) ...[
              const SizedBox(height: 10),
              Text(
                'Reserved amounts counted for ${budget.unknownUsageCalls} '
                '${budget.unknownUsageCalls == 1 ? 'request' : 'requests'} with unknown usage.',
                style: const TextStyle(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _usageValue(String title, int amount) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(title, style: const TextStyle(color: muted)),
      Text(
        formatPoundsMicros(amount),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ],
  );

  Widget _settingsContent() {
    final api = _route == AiRoute.api;
    final local = _route == AiRoute.local;
    final existingKey =
        _hasKey && _apiUrl.text.trim() == _runtime.settings.apiBaseUrl;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 26),
      children: [
        Wrap(
          spacing: 7,
          runSpacing: 5,
          children: [
            for (final (route, label) in [
              (AiRoute.offline, 'Offline'),
              (AiRoute.local, 'Local'),
              (AiRoute.api, 'API'),
            ])
              ChoiceChip(
                label: Text(label),
                selected: _route == route,
                showCheckmark: false,
                onSelected: (_) => _selectRoute(route),
              ),
          ],
        ),
        const SizedBox(height: 18),
        _usage(),
        const SizedBox(height: 14),
        _money(_cap, 'Monthly API limit'),
        if (api || local) ...[
          const SizedBox(height: 20),
          Text(
            api ? 'API provider' : 'Loopback runtime',
            style: sectionHeadingStyle,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: api ? _apiUrl : _localUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onChanged: api ? (_) => setState(() {}) : null,
            decoration: InputDecoration(
              labelText: 'Base URL',
              hintText: api
                  ? 'https://provider.example/v1'
                  : 'http://127.0.0.1:11434/v1',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: api ? _apiModel : _localModel,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Model'),
          ),
        ],
        if (api) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _apiKey,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: InputDecoration(
              labelText: existingKey ? 'Replace API key' : 'API key',
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _runtime.persistentVault
                        ? 'System vault'
                        : 'Key lasts for this session',
                    style: const TextStyle(color: muted),
                  ),
                ),
                if (existingKey)
                  TextButton(
                    onPressed: _deleteKey,
                    child: const Text('Remove key'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _money(_inputRate, 'Input rate per million tokens'),
          const SizedBox(height: 10),
          _money(_outputRate, 'Output rate per million tokens'),
        ],
        if (api || local)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Request limits'),
            children: [
              TextField(
                controller: _inputTokens,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Maximum input tokens',
                ),
              ),
              TextField(
                controller: _outputTokens,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Maximum output tokens',
                ),
              ),
              if (api)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _completionTokens,
                  title: const Text('Use completion token limit'),
                  onChanged: (value) =>
                      setState(() => _completionTokens = value),
                ),
            ],
          ),
        if (api || local)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _metadata,
            title: const Text('Include optional context'),
            subtitle: const Text(
              'Timezone, referred tasks and duration samples',
            ),
            onChanged: (value) => setState(() => _metadata = value),
          ),
        if (local)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _confirmLocal,
            title: const Text('Confirm local requests'),
            onChanged: (value) => setState(() => _confirmLocal = value),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _estimates,
          title: const Text('Suggest durations'),
          onChanged: (value) => setState(() => _estimates = value),
        ),
        if (_error case final error?)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FilledButton(
            onPressed: _saving || _runtime.busy ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save settings'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('AI settings'),
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: _loading
              ? const CircularProgressIndicator()
              : _runtime.storageReady
              ? _settingsContent()
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20),
                      child: Text('AI settings could not be loaded.'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () {
                        setState(() => _loading = true);
                        _load(refresh: true);
                      },
                      child: const Text('Reload'),
                    ),
                  ],
                ),
        ),
      ),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';

/// One export the CA/owner can pull from the accounting bridge.
enum ExportKind {
  tallyXml('Tally XML', 'xml', 'Tally Prime sales vouchers'),
  tallyCsv('Tally CSV', 'csv', 'Flat per-order sales table'),
  gstr1Json('GSTR-1 JSON', 'json', 'B2C invoices + HSN + rate summary'),
  gstr1Csv('GSTR-1 CSV', 'csv', 'B2C invoices + HSN + rate summary'),
  gstr3bJson('GSTR-3B JSON', 'json', 'Outward taxable supplies (4.1a)'),
  gstr3bCsv('GSTR-3B CSV', 'csv', 'Outward taxable supplies (4.1a)');

  const ExportKind(this.label, this.format, this.subtitle);

  final String label;
  final String format;
  final String subtitle;

  bool get isGst =>
      this == gstr1Json ||
      this == gstr1Csv ||
      this == gstr3bJson ||
      this == gstr3bCsv;
  bool get isGstr1 => this == gstr1Json || this == gstr1Csv;
  bool get isXml => this == tallyXml;
}

/// Shared exports UI for the owner and the read-only cafe_ca (CA) account:
/// pick a date range (Tally) or a GST period (GSTR-1/3B), fetch the file
/// from the backend, preview it as monospace text and copy it to the
/// clipboard (no share_plus — the CA pastes into Tally/spreadsheets).
class ExportsPanel extends StatefulWidget {
  const ExportsPanel({super.key});

  @override
  State<ExportsPanel> createState() => _ExportsPanelState();
}

class _ExportsPanelState extends State<ExportsPanel> {
  ExportKind _kind = ExportKind.tallyXml;
  DateTime _from = DateTime.now().subtract(const Duration(days: 7));
  DateTime _to = DateTime.now();
  DateTime _period = DateTime.now(); // GST month

  bool _loading = false;
  String? _error;
  String? _result;
  String? _resultLabel;

  Future<void> _pickDate({required bool isFrom}) async {
    final current = isFrom ? _from : _to;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        if (_to.isBefore(picked)) _to = picked;
      } else {
        _to = picked;
        if (_from.isAfter(picked)) _from = picked;
      }
    });
  }

  Future<void> _pickPeriod() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _period,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _period = picked);
  }

  String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  String _ym(DateTime d) => DateFormat('yyyy-MM').format(d);

  String _fileName() {
    switch (_kind) {
      case ExportKind.tallyXml:
      case ExportKind.tallyCsv:
        return 'tally_sales_${_ymd(_from)}_${_ymd(_to)}.${_kind.format}';
      case ExportKind.gstr1Json:
      case ExportKind.gstr1Csv:
        return 'gstr1_${_ym(_period)}.${_kind.format}';
      case ExportKind.gstr3bJson:
      case ExportKind.gstr3bCsv:
        return 'gstr3b_${_ym(_period)}.${_kind.format}';
    }
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<ApiClient>();
    try {
      final kind = _kind;
      String text;
      if (kind.isGst) {
        text = kind.isGstr1
            ? await api.fetchGstr1(_ym(_period), format: kind.format)
            : await api.fetchGstr3b(_ym(_period), format: kind.format);
      } else {
        text = await api.fetchTallyExport(
            from: _ymd(_from), to: _ymd(_to), format: kind.format);
      }
      if (!mounted) return;
      setState(() {
        _result = text;
        _resultLabel = _fileName();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _copy() async {
    final text = _result;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ---- Export kind ----
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Export',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'Files are in rupees. Tally XML imports straight into '
                  'Tally Prime; GST files follow the GSTR-1/3B tables.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final kind in ExportKind.values)
                      ChoiceChip(
                        label: Text(kind.label),
                        selected: _kind == kind,
                        onSelected: (_) => setState(() {
                          _kind = kind;
                          _result = null;
                          _error = null;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(_kind.subtitle,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // ---- Range / period picker ----
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _kind.isGst
                ? ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_month_outlined),
                    title: const Text('GST period (month)'),
                    subtitle: Text(_ym(_period)),
                    trailing: const Icon(Icons.edit_calendar_outlined),
                    onTap: _pickPeriod,
                  )
                : Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.event_outlined),
                        title: const Text('From'),
                        subtitle: Text(_ymd(_from)),
                        trailing: const Icon(Icons.edit_calendar_outlined),
                        onTap: () => _pickDate(isFrom: true),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.event_outlined),
                        title: const Text('To'),
                        subtitle: Text(_ymd(_to)),
                        trailing: const Icon(Icons.edit_calendar_outlined),
                        onTap: () => _pickDate(isFrom: false),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 12),

        FilledButton.icon(
          onPressed: _loading ? null : _fetch,
          icon: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_outlined),
          label: Text(_loading ? 'Fetching…' : 'Fetch ${_kind.label}'),
        ),
        const SizedBox(height: 12),

        if (_error != null)
          Card(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
          ),

        if (_result != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _resultLabel ?? 'export',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _copy,
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('Copy'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_result!.length} characters',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 360),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color:
                          scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _result!,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

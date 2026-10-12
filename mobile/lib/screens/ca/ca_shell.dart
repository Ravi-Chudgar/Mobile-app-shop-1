import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/sales_summary.dart';
import '../../services/api_client.dart';
import '../../state/auth_state.dart';
import '../../util/money.dart';
import '../../widgets/shell_app_bar.dart';
import 'exports_panel.dart';

/// Read-only shell for the cafe_ca (chartered accountant) login: daily
/// sales, the day-end Z-report, and the accounting exports. Every call it
/// makes is a GET the backend grants to the cafe_ca role — there are no
/// mutation entry points in this shell.
class CaShell extends StatefulWidget {
  const CaShell({super.key});

  @override
  State<CaShell> createState() => _CaShellState();
}

class _CaShellState extends State<CaShell> {
  int _index = 0;
  static const _titles = ['Daily Sales', 'Z-Report', 'Exports'];

  final _pages = const [
    CaDailyScreen(),
    CaZReportScreen(),
    ExportsPanel(),
  ];

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthState>();
    final name = auth.name ?? auth.username ?? 'CA';
    return Scaffold(
      appBar: ShellAppBar(
        title: _titles[_index],
        subtitle: shellDateLabel(),
        userName: name,
        onLogout: () => context.read<AuthState>().logout(),
      ),
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.today_outlined),
            selectedIcon: Icon(Icons.today),
            label: 'Daily',
          ),
          NavigationDestination(
            icon: Icon(Icons.point_of_sale_outlined),
            selectedIcon: Icon(Icons.point_of_sale),
            label: 'Z-Report',
          ),
          NavigationDestination(
            icon: Icon(Icons.file_upload_outlined),
            selectedIcon: Icon(Icons.file_upload),
            label: 'Exports',
          ),
        ],
      ),
    );
  }
}

/// CA view of one day's sales (read-only daily report).
class CaDailyScreen extends StatefulWidget {
  const CaDailyScreen({super.key});

  @override
  State<CaDailyScreen> createState() => _CaDailyScreenState();
}

class _CaDailyScreenState extends State<CaDailyScreen> {
  DateTime _day = DateTime.now();
  SalesSummary? _data;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await context.read<ApiClient>().dailyReport(_ymd(_day));
      if (!mounted) return;
      setState(() {
        _data = data;
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

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _day = picked);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = _data;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.event_outlined),
            title: const Text('Day'),
            subtitle: Text(_ymd(_day)),
            trailing: const Icon(Icons.edit_calendar_outlined),
            onTap: _pickDay,
          ),
        ),
        const SizedBox(height: 12),
        if (_loading) const Center(child: CircularProgressIndicator()),
        if (_error != null)
          Card(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
          ),
        if (!_loading && _error == null && data != null) ...[
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Gross sales',
                  value: formatMoney(data.grossSales),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  label: 'Orders',
                  value: '${data.orderCount}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('By payment method',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  ...data.byPayment.entries.map((e) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(e.key),
                        trailing: Text(
                          formatMoney(e.value),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      )),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// CA view of the day-end Z-report (totals, GST breakup, payment split).
class CaZReportScreen extends StatefulWidget {
  const CaZReportScreen({super.key});

  @override
  State<CaZReportScreen> createState() => _CaZReportScreenState();
}

class _CaZReportScreenState extends State<CaZReportScreen> {
  DateTime _day = DateTime.now();
  Map<String, dynamic>? _data;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await context.read<ApiClient>().zReport(_ymd(_day));
      if (!mounted) return;
      setState(() {
        _data = data;
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

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _day = picked);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = _data;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.event_outlined),
            title: const Text('Z-report day'),
            subtitle: Text(_ymd(_day)),
            trailing: const Icon(Icons.edit_calendar_outlined),
            onTap: _pickDay,
          ),
        ),
        const SizedBox(height: 12),
        if (_loading) const Center(child: CircularProgressIndicator()),
        if (_error != null)
          Card(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
          ),
        if (!_loading && _error == null && data != null) ...[
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Gross sales',
                  value: formatMoney((data['gross_sales'] ?? 0) as int),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  label: 'Tax (CGST+SGST)',
                  value: formatMoney((data['tax_total'] ?? 0) as int),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('GST by rate',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  ...((data['tax_by_rate'] ?? []) as List).map((row) {
                    final r = row as Map<String, dynamic>;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('GST @ ${r['rate'] ?? 0}%'),
                      subtitle: Text(
                        'taxable ${formatMoney((r['taxable'] ?? 0) as int)}',
                      ),
                      trailing: Text(
                        'CGST ${formatMoney((r['cgst'] ?? 0) as int)}  '
                        'SGST ${formatMoney((r['sgst'] ?? 0) as int)}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    );
                  }),
                  const Divider(),
                  ...((data['by_payment'] ?? {}) as Map<String, dynamic>)
                      .entries
                      .map((e) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(e.key),
                            trailing: Text(
                              formatMoney((e.value ?? 0) as int),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          )),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Small stat tile used by the CA daily/Z screens.
class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Text(
              value,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

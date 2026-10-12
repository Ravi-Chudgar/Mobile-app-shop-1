import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../../state/auth_state.dart';
import '../../util/money.dart';
import '../customer/menu_screen.dart';

/// Owner "Growth" hub: loyalty lookup, delivery-partner orders and the
/// table QR cards — the Phase 3 hooks in one screen so the owner shell
/// only needs a single new entry.
class GrowthScreen extends StatefulWidget {
  const GrowthScreen({super.key});

  @override
  State<GrowthScreen> createState() => _GrowthScreenState();
}

class _GrowthScreenState extends State<GrowthScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Growth'),
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: 'Loyalty'),
            Tab(text: 'Delivery'),
            Tab(text: 'Table QRs'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: const [
          _LoyaltyTab(),
          _DeliveryTab(),
          _TableQrTab(),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------- #
// Loyalty lookup + manual adjustment
// --------------------------------------------------------------------------- //

class _LoyaltyTab extends StatefulWidget {
  const _LoyaltyTab();

  @override
  State<_LoyaltyTab> createState() => _LoyaltyTabState();
}

class _LoyaltyTabState extends State<_LoyaltyTab>
    with AutomaticKeepAliveClientMixin {
  final _phoneCtrl = TextEditingController();
  final _deltaCtrl = TextEditingController(text: '10');
  final _reasonCtrl = TextEditingController();
  Map<String, dynamic>? _account;
  bool _loading = false;
  bool _adjusting = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _deltaCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _search([String? phone]) async {
    final query = (phone ?? _phoneCtrl.text).trim();
    if (query.isEmpty) {
      setState(() => _error = 'Enter a phone number');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await context.read<ApiClient>().fetchLoyalty(query);
      if (!mounted) return;
      setState(() {
        _account = data;
        _loading = false;
        _phoneCtrl.text = (data['phone'] as String?) ?? query;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _adjust(int direction) async {
    final phone = _phoneCtrl.text.trim();
    final delta = int.tryParse(_deltaCtrl.text.trim());
    final reason = _reasonCtrl.text.trim();
    if (phone.isEmpty || delta == null || delta <= 0 || reason.isEmpty) {
      setState(() =>
          _error = 'Phone, a positive points amount and a reason are required');
      return;
    }
    setState(() {
      _adjusting = true;
      _error = null;
    });
    try {
      final data = await context.read<ApiClient>().adjustLoyalty(
            phone: phone,
            delta: direction * delta,
            reason: reason,
          );
      if (!mounted) return;
      setState(() {
        _account = data;
        _adjusting = false;
        _reasonCtrl.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Balance updated: ${data['points']} points')));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _adjusting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final account = _account;
    final ledger = ((account?['ledger'] ?? []) as List);
    final pointValue = (account?['point_value_paise'] as num?)?.toInt() ?? 100;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Customer phone',
                  prefixIcon: Icon(Icons.phone_outlined),
                  hintText: '98765 43210',
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: _loading ? null : _search,
              child: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Search'),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: Colors.red.shade700)),
        ],
        if (account != null) ...[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Points balance',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${account['points'] ?? 0}',
                          style: const TextStyle(
                              fontSize: 34, fontWeight: FontWeight.w800)),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '= ${formatMoney(((account['points'] as num?)?.toInt() ?? 0) * pointValue)}',
                          style: const TextStyle(color: Colors.black54),
                        ),
                      ),
                    ],
                  ),
                  if (account['updated_at'] != null)
                    Text('Updated ${account['updated_at']}',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Adjust balance',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      SizedBox(
                        width: 90,
                        child: TextField(
                          controller: _deltaCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Points', isDense: true),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _reasonCtrl,
                          decoration: const InputDecoration(
                              labelText: 'Reason', isDense: true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _adjusting ? null : () => _adjust(-1),
                          icon: const Icon(Icons.remove, size: 18),
                          label: const Text('Deduct'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _adjusting ? null : () => _adjust(1),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add points'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Recent activity',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (ledger.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No points activity yet.'),
              ),
            ),
          for (final raw in ledger)
            Builder(builder: (context) {
              final entry = Map<String, dynamic>.from(raw as Map);
              final delta = (entry['delta'] as num?)?.toInt() ?? 0;
              return Card(
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    delta >= 0 ? Icons.add_circle : Icons.remove_circle,
                    color: delta >= 0 ? Colors.green : Colors.red,
                  ),
                  title: Text('${entry['reason'] ?? ''}'),
                  subtitle: Text('${entry['ts'] ?? ''}'),
                  trailing: Text(
                    '${delta > 0 ? '+' : ''}$delta',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: delta >= 0 ? Colors.green : Colors.red,
                    ),
                  ),
                ),
              );
            }),
        ],
      ],
    );
  }
}

// --------------------------------------------------------------------------- #
// Delivery orders (Swiggy / Zomato)
// --------------------------------------------------------------------------- //

class _DeliveryTab extends StatefulWidget {
  const _DeliveryTab();

  @override
  State<_DeliveryTab> createState() => _DeliveryTabState();
}

class _DeliveryTabState extends State<_DeliveryTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  String? _error;

  static const _excludedSources = {'counter', 'qr'};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orders = await context.read<ApiClient>().fetchOrdersRaw();
      if (!mounted) return;
      setState(() {
        _orders = orders
            .where((o) => !_excludedSources
                .contains((o['source'] ?? 'counter').toString()))
            .toList();
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$_error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_orders.isEmpty) {
      return const Center(
        child: Text('No delivery orders yet.\nSwiggy/Zomato orders land here.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _orders.length,
        itemBuilder: (context, i) {
          final o = _orders[i];
          final source = (o['source'] ?? '').toString();
          final customer = ((o['customer'] ?? {}) as Map)['name'] ?? 'Guest';
          final total = (o['total'] as num?)?.toInt() ?? 0;
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: source == 'swiggy'
                    ? Colors.orange.shade100
                    : Colors.red.shade50,
                child: Icon(
                  Icons.delivery_dining,
                  color: source == 'swiggy'
                      ? Colors.orange.shade800
                      : Colors.red.shade700,
                ),
              ),
              title: Row(
                children: [
                  Text('#${o['id']}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  _StatusChip(status: (o['status'] ?? '').toString()),
                ],
              ),
              subtitle: Text(
                  '$customer • ${o['pickup_type'] ?? 'delivery'} • ${source.toUpperCase()}'),
              trailing: Text(formatMoney(total),
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
            ),
          );
        },
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'received' => Colors.blue,
      'preparing' => Colors.orange,
      'ready' => Colors.teal,
      'collected' => Colors.green,
      'cancelled' => Colors.red,
      _ => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(status,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

// --------------------------------------------------------------------------- #
// Table QR cards
// --------------------------------------------------------------------------- //

class _TableQrTab extends StatefulWidget {
  const _TableQrTab();

  @override
  State<_TableQrTab> createState() => _TableQrTabState();
}

class _TableQrTabState extends State<_TableQrTab>
    with AutomaticKeepAliveClientMixin {
  List<String> _tables = [];
  String? _selected;
  String? _tenant;
  Uint8List? _png;
  String? _url;
  bool _loadingTables = true;
  bool _loadingQr = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadTables();
  }

  Future<void> _loadTables() async {
    setState(() {
      _loadingTables = true;
      _error = null;
    });
    try {
      final tables = await context.read<ApiClient>().fetchTables();
      if (!mounted) return;
      setState(() {
        _tables = tables.map((t) => t.number).toList();
        _selected ??= _tables.isEmpty ? null : _tables.first;
        _loadingTables = false;
      });
      if (_selected != null) _loadQr(_selected!);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loadingTables = false;
      });
    }
  }

  Future<void> _loadQr(String table) async {
    setState(() {
      _loadingQr = true;
      _error = null;
      _png = null;
      _url = null;
    });
    try {
      final api = context.read<ApiClient>();
      // The signed-in session already knows its cafe code; the QR must be
      // generated (and previewed) for that cafe so scans land in the right
      // business. Null tenant = default cafe, legacy card format.
      final tenant = context.read<AuthState>().tenant;
      _tenant = tenant;
      final png = await api.fetchTableQrPng(table, tenant: tenant);
      String? url;
      try {
        url = await api.fetchTableQrUrl(table, tenant: tenant);
      } catch (_) {
        url = null; // header fallback: not critical for display
      }
      if (!mounted) return;
      setState(() {
        _png = png;
        _url = url;
        _loadingQr = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loadingQr = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loadingTables) return const Center(child: CircularProgressIndicator());

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
            'Show or print this QR on the table — customers scan it to open '
            'the self-order menu.'),
        const SizedBox(height: 12),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final t in _tables)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('Table $t'),
                    selected: _selected == t,
                    onSelected: (_) {
                      setState(() => _selected = t);
                      _loadQr(t);
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Text(_error!, style: TextStyle(color: Colors.red.shade700)),
        if (_loadingQr)
          const Center(
              child: Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(),
          )),
        if (!_loadingQr && _png != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text('Table ${_selected ?? ''}',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  Image.memory(_png!, width: 240, height: 240),
                  if (_url != null) ...[
                    const SizedBox(height: 12),
                    Text(_url!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54)),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _url == null
                              ? null
                              : () {
                                  Clipboard.setData(ClipboardData(text: _url!));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('Link copied')));
                                },
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy link'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CustomerMenuScreen(
                                  tableNumber: _selected, tenant: _tenant),
                            ),
                          ),
                          icon: const Icon(Icons.smartphone, size: 18),
                          label: const Text('Preview'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

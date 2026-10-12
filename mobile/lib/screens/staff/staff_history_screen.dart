import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/order.dart';
import '../../services/api_client.dart';
import '../../state/auth_state.dart';
import '../../util/money.dart';

/// Staff order history: every order this logged-in staff member took, with
/// their own sales totals. Each staff member only sees their own history.
class StaffHistoryScreen extends StatefulWidget {
  const StaffHistoryScreen({super.key});

  @override
  State<StaffHistoryScreen> createState() => _StaffHistoryScreenState();
}

class _StaffHistoryScreenState extends State<StaffHistoryScreen> {
  final _fmt = DateFormat('d MMM, h:mm a');
  List<CafeOrder> _orders = [];
  bool _loading = true;
  String? _error;
  String _filter = 'all'; // all | active | completed

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
    final username = context.read<AuthState>().username;
    try {
      final orders =
          await context.read<ApiClient>().fetchOrders(takenBy: username);
      if (!mounted) return;
      setState(() {
        _orders = orders;
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

  Color _statusColor(String status) {
    switch (status) {
      case 'received':
        return Colors.blueGrey;
      case 'preparing':
        return Colors.orange;
      case 'ready':
        return Colors.green;
      case 'collected':
        return Colors.grey;
      default:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }

    final visible = _orders.where((o) {
      switch (_filter) {
        case 'active':
          return o.status != 'collected';
        case 'completed':
          return o.status == 'collected';
        default:
          return true;
      }
    }).toList();

    final completed = _orders.where((o) => o.status == 'collected').toList();
    final revenue = completed.fold<int>(0, (sum, o) => sum + o.total);
    final active = _orders.where((o) => o.status != 'collected').length;

    return RefreshIndicator(
      onRefresh: _load,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.45),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Stat('Orders taken', '${_orders.length}', Icons.receipt_long),
                _Stat('Revenue', formatMoney(revenue), Icons.payments),
                _Stat('Active', '$active', Icons.pending_actions),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                Text('My order history',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                for (final f in [
                  ('all', 'All'),
                  ('active', 'Active'),
                  ('completed', 'Completed'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.$2),
                      selected: _filter == f.$1,
                      onSelected: (_) => setState(() => _filter = f.$1),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 100),
                    Center(child: Text('No orders yet for this staff.')),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final o = visible[i];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text('#${o.id}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16)),
                                  const SizedBox(width: 8),
                                  Chip(
                                    label: Text(o.status,
                                        style: const TextStyle(
                                            color: Colors.white, fontSize: 12)),
                                    backgroundColor: _statusColor(o.status),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  const Spacer(),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(formatMoney(o.total),
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(Icons.person_outline,
                                      size: 14, color: Colors.grey.shade600),
                                  const SizedBox(width: 4),
                                  Text(o.customerName,
                                      style: const TextStyle(fontSize: 13)),
                                  if (o.tableNumber != null) ...[
                                    const SizedBox(width: 12),
                                    Icon(Icons.table_restaurant_outlined,
                                        size: 14, color: Colors.grey.shade600),
                                    const SizedBox(width: 4),
                                    Text('Table ${o.tableNumber}',
                                        style: const TextStyle(fontSize: 13)),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(Icons.schedule,
                                      size: 14, color: Colors.grey.shade600),
                                  const SizedBox(width: 4),
                                  Text(
                                    _fmt.format(
                                        DateTime.tryParse(o.createdAt) ??
                                            DateTime.now()),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  const Spacer(),
                                  Text(
                                    '${o.items.fold<int>(0, (s, l) => s + l.qty)} item(s)',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _Stat(this.label, this.value, this.icon);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

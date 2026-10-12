import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../../services/offline/offline.dart';
import '../../util/money.dart';
import '../../widgets/ui_kit.dart';
import 'customer_cart.dart';
import 'customer_ui.dart';
import 'menu_screen.dart';
import 'order_status_screen.dart';

/// Final step of the QR flow: table + name + phone (both required), then
/// place the order and jump straight into status tracking.
/// [tenant] scopes the public call to the cafe the QR belongs to (null =
/// default cafe, legacy endpoint).
class CustomerCheckoutScreen extends StatefulWidget {
  final CustomerCart cart;
  final String? tenant;
  const CustomerCheckoutScreen({super.key, required this.cart, this.tenant});

  @override
  State<CustomerCheckoutScreen> createState() => _CustomerCheckoutScreenState();
}

class _CustomerCheckoutScreenState extends State<CustomerCheckoutScreen> {
  final _tableCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tableCtrl.text = widget.cart.tableNumber ?? '';
  }

  @override
  void dispose() {
    _tableCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  String? _validate() {
    if (_tableCtrl.text.trim().isEmpty) return 'Table number is required';
    if (_nameCtrl.text.trim().isEmpty) return 'Your name is required';
    final digits = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 10) return 'Enter a valid 10-digit phone number';
    return null;
  }

  Future<void> _place() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final table = _tableCtrl.text.trim();
    try {
      if (!ConnectivityMonitor.instance.isOnline.value) {
        throw const DeviceOfflineException(); // handled below, no wait
      }
      final order = await context.read<ApiClient>().placePublicOrder(
            tableNumber: table,
            items: widget.cart.itemsJson,
            name: _nameCtrl.text.trim(),
            phone: _phoneCtrl.text.trim(),
            tenant: widget.tenant,
          );
      if (!mounted) return;
      widget.cart.clear();
      // Drop menu/cart off the stack: back from tracking leaves the flow.
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => CustomerOrderStatusScreen(
            orderId: order.id,
            tableNumber: table,
            tenant: widget.tenant,
            onOrderMore: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(
                    builder: (_) => CustomerMenuScreen(
                        tableNumber: table, tenant: widget.tenant)),
                (route) => false,
              );
            },
          ),
        ),
        (route) => false,
      );
    } catch (e) {
      // Offline (or backend unreachable): keep the order on this device. The
      // queue replays it against the server's QR contract once a session can
      // reach the backend again — nothing is lost.
      if (isConnectivityError(e)) {
        await OfflineQueue.instance.enqueue(
          type: 'order_create',
          payload: {
            'source': 'qr',
            'table_number': table,
            'items': widget.cart.itemsJson,
            'customer': {
              'name': _nameCtrl.text.trim(),
              'phone': _phoneCtrl.text.trim(),
            },
          },
        );
        if (!mounted) return;
        widget.cart.clear();
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
              builder: (_) => CustomerMenuScreen(
                  tableNumber: table, tenant: widget.tenant)),
          (route) => false,
        );
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Offline — your order is saved on this device and will be '
                  'sent automatically once you reconnect'),
        ));
        return;
      }
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = widget.cart;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          HeroBanner(
            gradient: CafeGradients.peach,
            illustration: Align(
              alignment: const Alignment(1.05, 0.2),
              child: Opacity(
                opacity: 0.3,
                child: SizedBox(
                  width: 130,
                  height: 130,
                  child: CustomPaint(
                    painter: LatteArtPainter(withBeans: false),
                  ),
                ),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Almost ready 🎉',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${cart.count} ${cart.count == 1 ? 'item' : 'items'} • '
                  'GST included • pay at the counter',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _summaryCard(text),
          const SizedBox(height: 20),
          const SectionHeader(
            title: 'Who is this order for?',
            subtitle: 'We will call your name when it is ready',
          ),
          TextField(
            controller: _tableCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Table number',
                prefixIcon: Icon(Icons.table_restaurant)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: 'Your name', prefixIcon: Icon(Icons.person_outline)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            maxLength: 14,
            decoration: const InputDecoration(
                labelText: 'Phone number',
                helperText: 'For order updates and loyalty points',
                prefixIcon: Icon(Icons.phone_outlined)),
            onChanged: (_) => setState(() => _error = null),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
          ],
        ],
      ),
      bottomNavigationBar: BottomDock(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Total (GST incl.)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    formatMoney(cart.total),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            GradientPillButton(
              onPressed: _saving ? null : _place,
              gradient: CafeGradients.espresso,
              horizontalPadding: 26,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Place order'),
                        const SizedBox(width: 6),
                        Icon(
                          Icons.bolt_rounded,
                          size: 20,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(TextTheme text) {
    final cart = widget.cart;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const IconChip(
                  icon: Icons.receipt_long_outlined,
                  gradient: CafeGradients.coffee,
                  size: 38,
                  iconSize: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Order summary',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: CafePalette.latte,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${cart.count} ${cart.count == 1 ? 'item' : 'items'}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: CafePalette.coffee,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            for (final line in cart.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 26,
                      height: 24,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      decoration: BoxDecoration(
                        color: CafePalette.latte,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${line.qty}',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: CafePalette.espresso,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            line.item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (line.optionsSummary.isNotEmpty)
                            Text(
                              line.optionsSummary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: Colors.grey.shade600,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatMoney(line.lineTotal),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            const Divider(height: 18),
            Row(
              children: [
                const Expanded(
                  child: Text('Total (GST incl.)',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(formatMoney(cart.total),
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

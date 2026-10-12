import 'package:flutter/material.dart';

import '../../widgets/ui_kit.dart';
import 'customer_ui.dart';
import 'order_status_screen.dart';

/// Look up a QR order by its pickup number (printed on the order /
/// shown on the tracking screen) and jump into tracking.
/// [tenant] scopes the lookup to the cafe the order was placed in.
class CustomerOrderLookupScreen extends StatefulWidget {
  final String? tenant;
  const CustomerOrderLookupScreen({super.key, this.tenant});

  @override
  State<CustomerOrderLookupScreen> createState() =>
      _CustomerOrderLookupScreenState();
}

class _CustomerOrderLookupScreenState extends State<CustomerOrderLookupScreen> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _track() {
    final id = _ctrl.text.trim().toUpperCase();
    if (id.isEmpty) {
      setState(() => _error = 'Enter your order number');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            CustomerOrderStatusScreen(orderId: id, tenant: widget.tenant),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Track an order')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          HeroBanner(
            gradient: CafeGradients.espresso,
            illustration: Align(
              alignment: const Alignment(0.95, 0.1),
              child: Opacity(
                opacity: 0.3,
                child: SizedBox(
                  width: 150,
                  height: 150,
                  child: CustomPaint(painter: LatteArtPainter(withBeans: true)),
                ),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Find your order',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Enter the pickup number from your receipt and we will '
                  'show you exactly where it is.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.88),
                    fontSize: 13.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Order number',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'It looks like 3F9A21',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _ctrl,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      hintText: 'e.g. 3F9A21',
                      prefixIcon: Icon(Icons.receipt_long_outlined),
                    ),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _track(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 16, color: Colors.red.shade700),
                        const SizedBox(width: 6),
                        Text(_error!,
                            style: TextStyle(
                                color: Colors.red.shade700, fontSize: 13)),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  GradientPillButton(
                    onPressed: _track,
                    gradient: CafeGradients.coffee,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search_rounded, size: 20),
                        SizedBox(width: 8),
                        Text('Track order'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const EmptyStateArt(
            title: 'Lost your number?',
            message:
                'Ask at the counter — we can look your order up in seconds.',
            icon: Icons.receipt_long_outlined,
          ),
        ],
      ),
    );
  }
}

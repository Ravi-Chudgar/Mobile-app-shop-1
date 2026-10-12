import 'package:flutter/material.dart';

import '../../util/money.dart';
import '../../widgets/ui_kit.dart';
import 'checkout_screen.dart';
import 'customer_cart.dart';
import 'customer_ui.dart';

/// Review the self-order cart: adjust quantities, then head to checkout.
/// [tenant] is the cafe code the order belongs to (null = default cafe).
class CustomerCartScreen extends StatelessWidget {
  final CustomerCart cart;
  final String? tenant;
  const CustomerCartScreen({super.key, required this.cart, this.tenant});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Your order')),
          body: cart.isEmpty
              ? EmptyStateArt(
                  title: 'Your order is empty',
                  message:
                      'Add something delicious from the menu — your table is waiting',
                  action: FilledButton.tonal(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Browse the menu'),
                  ),
                )
              : _body(context),
          bottomNavigationBar: cart.isEmpty
              ? null
              : BottomDock(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${cart.count} ${cart.count == 1 ? 'item' : 'items'} • GST incl.',
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
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CustomerCheckoutScreen(
                                cart: cart, tenant: tenant),
                          ),
                        ),
                        horizontalPadding: 24,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Checkout'),
                            SizedBox(width: 4),
                            Icon(Icons.arrow_forward_rounded, size: 20),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      children: [
        _summaryHero(context),
        const SizedBox(height: 16),
        const SectionHeader(
          title: 'Items',
          subtitle: 'Adjust quantities, then head to checkout',
        ),
        for (var i = 0; i < cart.lines.length; i++) _lineCard(context, i),
      ],
    );
  }

  Widget _summaryHero(BuildContext context) {
    return HeroBanner(
      gradient: CafeGradients.coffee,
      illustration: Align(
        alignment: const Alignment(1.05, 0.4),
        child: Opacity(
          opacity: 0.25,
          child: SizedBox(
            width: 120,
            height: 120,
            child: CustomPaint(painter: LatteArtPainter(withBeans: false)),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cart.tableNumber == null
                      ? 'Table not set'
                      : 'Table ${cart.tableNumber}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.88),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  'Your order',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${cart.count} ${cart.count == 1 ? 'item' : 'items'}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                formatMoney(cart.total),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _lineCard(BuildContext context, int index) {
    final line = cart.lines[index];
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ItemArt(item: line.item, size: 56, fontSize: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          line.item.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatMoney(line.lineTotal),
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  if (line.optionsSummary.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      line.optionsSummary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${formatMoney(line.unitPrice)} each',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                      QtyStepper(
                        qty: line.qty,
                        onDecrement: () => cart.setQty(index, line.qty - 1),
                        onIncrement: () => cart.setQty(index, line.qty + 1),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

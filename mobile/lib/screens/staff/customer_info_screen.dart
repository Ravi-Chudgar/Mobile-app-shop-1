import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/cart_state.dart';
import 'take_order_screen.dart';

/// Ask for customer name before taking order on a table.
class CustomerInfoScreen extends StatefulWidget {
  final String tableNumber;
  const CustomerInfoScreen({super.key, required this.tableNumber});

  @override
  State<CustomerInfoScreen> createState() => _CustomerInfoScreenState();
}

class _CustomerInfoScreenState extends State<CustomerInfoScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _proceed() {
    if (!_formKey.currentState!.validate()) return;

    context.read<CartState>().setCustomerInfo(
          name: _nameController.text.trim(),
          phone: _phoneController.text.trim(),
        );

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => TakeOrderScreen(tableNumber: widget.tableNumber),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Table ${widget.tableNumber}'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            children: [
              // ── Table badge ──
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.table_restaurant_rounded,
                    size: 40,
                    color: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // ── Heading ──
              Text(
                'Who is this order for?',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Enter customer details to start the order',
                style: TextStyle(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),

              // ── Form ──
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Customer Name',
                        hintText: 'e.g., John Smith',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Name is required'
                          : null,
                      autofocus: true,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _phoneController,
                      decoration: const InputDecoration(
                        labelText: 'Mobile Number *',
                        hintText: 'e.g., 98765 43210',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.done,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Mobile number is required for WhatsApp bill';
                        }
                        final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
                        if (digits.length < 10) {
                          return 'Enter a valid 10-digit number';
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) => _proceed(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // ── CTA ──
              FilledButton(
                onPressed: _proceed,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text(
                  'Start Order',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/inventory_item.dart';
import '../../services/api_client.dart';

const _units = ['piece', 'kg', 'g', 'litre', 'ml', 'dozen', 'pack'];

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  List<InventoryItem> _inventory = [];
  List<LowStockAlert> _alerts = [];
  int _totalValue = 0;
  int _totalItems = 0;
  bool _loading = true;
  String? _error;

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
    final api = context.read<ApiClient>();
    try {
      final inventory = await api.fetchInventory();
      final summary = await api.fetchInventorySummary();
      List<LowStockAlert> alerts = [];
      try {
        alerts = await api.fetchInventoryAlerts();
      } catch (_) {
        // Alerts are advisory — the list still works without them.
      }
      setState(() {
        _inventory = inventory;
        _alerts = alerts;
        _totalValue = summary['total_value'] as int? ?? 0;
        _totalItems = summary['total_items'] as int? ?? 0;
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

  Future<void> _addItem() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _AddEditItemDialog(),
    );
    if (result == null) return;
    if (!mounted) return;
    final api = context.read<ApiClient>();
    try {
      await api.createInventoryItem(result);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add item: $e')),
      );
    }
  }

  Future<void> _editItem(InventoryItem item) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _AddEditItemDialog(item: item),
    );
    if (result == null) return;
    if (!mounted) return;
    final api = context.read<ApiClient>();
    try {
      await api.updateInventoryItem(item.id, result);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update: $e')),
      );
    }
  }

  Future<void> _restockItem(InventoryItem item) async {
    final qtyController = TextEditingController();
    final result = await showDialog<int>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Restock ${item.name}'),
        content: TextField(
          controller: qtyController,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Quantity to add (${item.unit})',
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final qty = int.tryParse(qtyController.text);
              if (qty != null && qty > 0) Navigator.pop(context, qty);
            },
            child: const Text('Restock'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (!mounted) return;
    final api = context.read<ApiClient>();
    try {
      await api.restockItem(item.id, result);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to restock: $e')),
      );
    }
  }

  Future<void> _deleteItem(InventoryItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Item'),
        content: Text('Remove "${item.name}" from inventory?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!mounted) return;
    final api = context.read<ApiClient>();
    try {
      await api.deleteInventoryItem(item.id);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: $e')),
      );
    }
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return 'Not set';
    try {
      final dt = DateTime.parse(dateStr);
      return DateFormat('dd MMM yyyy, hh:mm a').format(dt);
    } catch (_) {
      return dateStr;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Inventory')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Inventory')),
        body: _ErrorView(message: _error!, onRetry: _load),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Inventory')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Inventory Management',
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _addItem,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Item'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _MetricCard(
                    title: 'Total Items',
                    value: '$_totalItems',
                    emoji: '📦',
                    subtitle: 'in stock',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MetricCard(
                    title: 'Total Value',
                    value: '₹$_totalValue',
                    emoji: '💰',
                    subtitle: 'cost basis',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_alerts.isNotEmpty) ...[
              _LowStockBanner(alerts: _alerts),
              const SizedBox(height: 16),
            ],
            Text(
              'Items (${_inventory.length})',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (_inventory.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'No inventory items yet.\nTap "Add Item" to get started.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              )
            else
              ..._inventory.map((item) => _InventoryTile(
                    item: item,
                    onEdit: () => _editItem(item),
                    onRestock: () => _restockItem(item),
                    onDelete: () => _deleteItem(item),
                    formatDate: _formatDate,
                  )),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String title;
  final String value;
  final String emoji;
  final String subtitle;
  const _MetricCard({
    required this.title,
    required this.value,
    required this.emoji,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(emoji, style: const TextStyle(fontSize: 24, height: 0)),
              ],
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1)),
            ),
            const SizedBox(height: 6),
            Text(subtitle,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

class _InventoryTile extends StatelessWidget {
  final InventoryItem item;
  final VoidCallback onEdit;
  final VoidCallback onRestock;
  final VoidCallback onDelete;
  final String Function(String?) formatDate;
  const _InventoryTile({
    required this.item,
    required this.onEdit,
    required this.onRestock,
    required this.onDelete,
    required this.formatDate,
  });

  @override
  Widget build(BuildContext context) {
    final lowStock = item.isLowStock;
    final outOfStock = item.isOutOfStock;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: lowStock || outOfStock
                  ? scheme.errorContainer
                  : scheme.primaryContainer,
              child: Text(
                item.name.substring(0, 1).toUpperCase(),
                style: TextStyle(
                  color: lowStock || outOfStock
                      ? scheme.onErrorContainer
                      : scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (outOfStock)
                        _StatusPill(
                          label: 'OUT',
                          color: scheme.error,
                          background: scheme.errorContainer,
                        )
                      else if (lowStock)
                        _StatusPill(
                          label: item.hasReorderLevel
                              ? 'LOW ${item.quantity}/${item.reorderLevel}'
                              : 'LOW',
                          color: scheme.error,
                          background: scheme.errorContainer,
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '${item.quantity} ${item.unit}',
                        style: TextStyle(
                          color: lowStock || outOfStock
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                          fontSize: 13,
                          fontWeight: lowStock || outOfStock
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      if (item.hasReorderLevel) ...[
                        const SizedBox(width: 6),
                        Text(
                          'reorder at ${item.reorderLevel}',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Bought: ${formatDate(item.purchaseDate)}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '₹${item.costPrice}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    onEdit();
                    break;
                  case 'restock':
                    onRestock();
                    break;
                  case 'delete':
                    onDelete();
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                const PopupMenuItem(value: 'restock', child: Text('Restock')),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AddEditItemDialog extends StatefulWidget {
  final InventoryItem? item;
  const _AddEditItemDialog({this.item});

  @override
  State<_AddEditItemDialog> createState() => _AddEditItemDialogState();
}

class _AddEditItemDialogState extends State<_AddEditItemDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _costCtrl;
  late final TextEditingController _reorderCtrl;
  late String _unit;
  late DateTime _purchaseDate;

  bool get isEditing => widget.item != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.item?.name ?? '');
    _qtyCtrl = TextEditingController(
        text: isEditing ? widget.item!.quantity.toString() : '0');
    _costCtrl = TextEditingController(
        text: isEditing ? widget.item!.costPrice.toString() : '');
    _reorderCtrl = TextEditingController(
        text: isEditing ? widget.item!.reorderLevel.toString() : '0');
    _unit = widget.item?.unit ?? 'piece';

    if (isEditing && widget.item!.purchaseDate != null) {
      try {
        _purchaseDate = DateTime.parse(widget.item!.purchaseDate!);
      } catch (_) {
        _purchaseDate = DateTime.now();
      }
    } else {
      _purchaseDate = DateTime.now();
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    _costCtrl.dispose();
    _reorderCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _purchaseDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    if (!mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_purchaseDate),
    );

    setState(() {
      _purchaseDate = DateTime(
        picked.year,
        picked.month,
        picked.day,
        time?.hour ?? _purchaseDate.hour,
        time?.minute ?? _purchaseDate.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd MMM yyyy, hh:mm a');
    return AlertDialog(
      title: Text(isEditing ? 'Edit Item' : 'Add Inventory Item'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Item Name',
                  hintText: 'e.g. Sugar, Coffee Beans',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Name is required' : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _qtyCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Quantity',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Required';
                        if (int.tryParse(v) == null) return 'Must be a number';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      value: _unit,
                      decoration: const InputDecoration(
                        labelText: 'Unit',
                        border: OutlineInputBorder(),
                      ),
                      items: _units
                          .map(
                              (u) => DropdownMenuItem(value: u, child: Text(u)))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _unit = v);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _costCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Price (₹)',
                  border: OutlineInputBorder(),
                  hintText: 'e.g. 230',
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Required';
                  if (int.tryParse(v) == null) return 'Must be a number';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _reorderCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Reorder level',
                  hintText: 'e.g. 10',
                  helperText:
                      'Low-stock alert when qty drops to this. 0 = off.',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  final n = int.tryParse(v.trim());
                  if (n == null) return 'Must be a number';
                  if (n < 0) return 'Must be 0 or more';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Purchase Date & Time',
                    border: OutlineInputBorder(),
                    suffixIcon: Icon(Icons.calendar_today),
                  ),
                  child: Text(dateFmt.format(_purchaseDate)),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(context, {
                'name': _nameCtrl.text.trim(),
                'quantity': int.parse(_qtyCtrl.text),
                'cost_price': int.parse(_costCtrl.text),
                'unit': _unit,
                'reorder_level': int.parse(_reorderCtrl.text.trim()),
                'purchase_date': _purchaseDate.toUtc().toIso8601String(),
              });
            }
          },
          child: Text(isEditing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40, color: Colors.grey),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// Header banner listing items that hit their reorder level (or sold out).
class _LowStockBanner extends StatelessWidget {
  final List<LowStockAlert> alerts;
  const _LowStockBanner({required this.alerts});

  @override
  Widget build(BuildContext context) {
    final outOfStock = alerts.where((a) => a.outOfStock).length;
    final names = alerts.take(3).map((a) => a.item).join(', ');
    final more = alerts.length > 3 ? ' +${alerts.length - 3} more' : '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.shade400),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.amber.shade800),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${alerts.length} low-stock item${alerts.length == 1 ? '' : 's'}'
                  '${outOfStock > 0 ? ' ($outOfStock out of stock)' : ''}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.amber.shade900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$names$more',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.amber.shade900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small pill used for LOW / OUT badges on inventory rows.
class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final Color background;
  const _StatusPill({
    required this.label,
    required this.color,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

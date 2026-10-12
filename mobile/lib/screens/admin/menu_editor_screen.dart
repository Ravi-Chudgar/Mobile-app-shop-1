import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/menu_item.dart';
import '../../services/api_client.dart';
import '../../util/money.dart';
import '../../widgets/menu_image.dart';

class MenuEditorScreen extends StatefulWidget {
  const MenuEditorScreen({super.key});

  @override
  State<MenuEditorScreen> createState() => _MenuEditorScreenState();
}

class _MenuEditorScreenState extends State<MenuEditorScreen> {
  List<MenuItem> _items = [];
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
    try {
      final items = await context.read<ApiClient>().fetchMenu();
      if (!mounted) return;
      setState(() {
        _items = items;
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

  Future<void> _toggle(MenuItem item, bool available) async {
    try {
      await context.read<ApiClient>().setAvailability(item.id, available);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(MenuItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${item.name}?'),
        content: const Text('This removes the item from the menu.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    if (!mounted) return;
    try {
      await context.read<ApiClient>().deleteMenuItem(item.id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _addItem() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ItemSheet(),
    );
    if (changed == true) _load();
  }

  Future<void> _editItem(MenuItem item) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ItemSheet(initial: item),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Menu Editor')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: _items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final item = _items[i];
            return ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: MenuImage(url: item.imageUrl, width: 48, height: 48),
              ),
              title: Text(item.name),
              subtitle: Text('${item.category} • ${formatMoney(item.basePrice)}'
                  ' • GST ${item.gstRate}% • HSN ${item.hsnCode}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Edit (price & GST)',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _editItem(item),
                  ),
                  Switch(
                    value: item.available,
                    onChanged: (v) => _toggle(item, v),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _delete(item),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addItem,
        icon: const Icon(Icons.add),
        label: const Text('Add item'),
      ),
    );
  }
}

/// Create (initial == null) or edit a menu item, including its GST rate and
/// HSN/SAC code. Prices are entered in rupees, stored in paise.
class _ItemSheet extends StatefulWidget {
  final MenuItem? initial;
  const _ItemSheet({this.initial});

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _price;
  late final TextEditingController _hsn;
  late String _category;
  late int _gstRate;
  bool _busy = false;

  bool get _isEdit => widget.initial != null;

  static const _categories = [
    'coffee',
    'tea',
    'cold_drinks',
    'food',
    'pastries'
  ];

  // Indian GST slabs: 0 (essentials), 5 (restaurant service), 12, 18.
  static const _gstRates = [0, 5, 12, 18];

  @override
  void initState() {
    super.initState();
    final item = widget.initial;
    _name = TextEditingController(text: item?.name ?? '');
    _desc = TextEditingController(text: item?.description ?? '');
    _price = TextEditingController(
        text: item == null ? '' : (item.basePrice / 100).toStringAsFixed(2));
    _hsn = TextEditingController(text: item?.hsnCode ?? '9963');
    _category = item != null && _categories.contains(item.category)
        ? item.category
        : 'coffee';
    _gstRate = item?.gstRate ?? 5;
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _price.dispose();
    _hsn.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    // Price entered in major units -> store as minor units.
    final major = double.tryParse(_price.text.trim()) ?? 0;
    final payload = {
      'name': _name.text.trim(),
      'description': _desc.text.trim(),
      'category': _category,
      'base_price': (major * 100).round(),
      'gst_rate': _gstRate,
      'hsn_code': _hsn.text.trim().isEmpty ? '9963' : _hsn.text.trim(),
      if (!_isEdit) ...{
        'available': true,
        'options': [],
      },
    };
    try {
      final api = context.read<ApiClient>();
      if (_isEdit) {
        await api.updateMenuItem(widget.initial!.id, payload);
      } else {
        await api.createMenuItem(payload);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_isEdit ? 'Edit menu item' : 'New menu item',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                  labelText: 'Name', border: OutlineInputBorder()),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _category,
                    decoration: const InputDecoration(
                        labelText: 'Category', border: OutlineInputBorder()),
                    items: _categories
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                    onChanged: (v) => setState(() => _category = v!),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: _gstRate,
                    decoration: const InputDecoration(
                        labelText: 'GST %', border: OutlineInputBorder()),
                    items: _gstRates
                        .map((r) =>
                            DropdownMenuItem(value: r, child: Text('$r%')))
                        .toList(),
                    onChanged: (v) => setState(() => _gstRate = v ?? 5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _price,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Price (e.g. 3.20)',
                        border: OutlineInputBorder()),
                    validator: (v) {
                      final n = double.tryParse((v ?? '').trim());
                      if (n == null || n <= 0) return 'Enter a valid price';
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _hsn,
                    decoration: const InputDecoration(
                        labelText: 'HSN / SAC code',
                        hintText: '9963',
                        border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _desc,
              decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  border: OutlineInputBorder()),
              maxLines: 2,
            ),
            const SizedBox(height: 6),
            Text(
              'Menu prices are inclusive of GST.',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

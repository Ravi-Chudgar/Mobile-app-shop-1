import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/cafe_table.dart';
import '../../models/order.dart';
import '../../services/api_client.dart';
import '../../util/money.dart';
import '../../widgets/ui_kit.dart';

/// Owner view: see table occupancy with staff assignments, add/remove tables,
/// view order details — and arrange the visual floor map (move/resize tables).
class TablesAdminScreen extends StatefulWidget {
  const TablesAdminScreen({super.key});

  @override
  State<TablesAdminScreen> createState() => _TablesAdminScreenState();
}

class _TablesAdminScreenState extends State<TablesAdminScreen> {
  /// In-memory view preference (no persistence dependency in the app).
  static bool _floorView = false;

  /// Floor view only: drag-to-move / tap-to-edit mode.
  bool _editMode = false;

  List<CafeTable> _tables = [];
  final Map<String, CafeOrder?> _orderCache = {};
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
      final tables = await api.fetchTables();
      _orderCache.clear();

      // Fetch all orders to map to tables
      final orders = await api.fetchOrders();
      for (final order in orders) {
        if (order.id.isNotEmpty) {
          _orderCache[order.id] = order;
        }
      }

      if (!mounted) return;
      setState(() {
        _tables = tables;
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

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _addTable() async {
    try {
      await context.read<ApiClient>().addTable();
      await _load();
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _removeTable(CafeTable t) async {
    try {
      await context.read<ApiClient>().removeTable(t.number);
      await _load();
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _freeTable(CafeTable t) async {
    try {
      await context.read<ApiClient>().freeTable(t.number);
      await _load();
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _showTableDetails(CafeTable table) async {
    final order = table.orderId != null ? _orderCache[table.orderId] : null;
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            gradient: table.isOccupied
                                ? CafeGradients.peach
                                : CafeGradients.mint,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.table_restaurant_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Table ${table.number}',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: table.isOccupied
                            ? CafePalette.peach.withValues(alpha: 0.16)
                            : CafePalette.mint.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        table.isOccupied ? 'Occupied' : 'Empty',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: table.isOccupied
                              ? const Color(0xFF9A4A2B)
                              : const Color(0xFF2F6B51),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (table.isOccupied && order != null) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: CafePalette.latte.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: CafePalette.caramel.withValues(alpha: 0.45)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Order Details',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Order #',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                                Text(
                                  order.id,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                const Text(
                                  'Status',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                                Chip(
                                  label: Text(order.status),
                                  backgroundColor: _statusColor(order.status)
                                      .withValues(alpha: 0.3),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Customer',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                                Text(
                                  order.customerName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                const Text(
                                  'Total',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                                Text(
                                  formatMoney(order.total),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Items',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...order.items.map((line) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Text(
                              '${line.qty}×',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(line.name),
                                  if (line.options.isNotEmpty)
                                    Text(
                                      line.options.join(' • '),
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.black54,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Text(
                              formatMoney(line.lineTotal),
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      )),
                  const SizedBox(height: 12),
                  const Divider(),
                ] else if (table.isOccupied) ...[
                  const Text('Loading order details...'),
                ] else ...[
                  const Text(
                    'This table is empty.',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],
                const SizedBox(height: 16),
                if (table.isOccupied)
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: CafePalette.mint,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      _freeTable(table);
                    },
                    child: const SizedBox(
                      width: double.infinity,
                      child: Text(
                        'Free this table',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                else
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: CafePalette.berry,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      _removeTable(table);
                    },
                    child: const SizedBox(
                      width: double.infinity,
                      child: Text(
                        'Remove this table',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Floor map editor ----------------------------------------------------

  Color _statusColor(String status) {
    switch (status) {
      case 'received':
        return CafePalette.sky;
      case 'preparing':
        return CafePalette.sunshine;
      case 'ready':
        return CafePalette.mint;
      case 'collected':
        return Colors.grey;
      default:
        return CafePalette.berry;
    }
  }

  TableRect _rectOf(CafeTable t, int index) => t.hasLayout
      ? TableRect(t.x!, t.y!, t.w!, t.h!)
      : fallbackRect(index, total: _tables.length);

  Future<void> _persistLayout(CafeTable t) async {
    if (t.x == null || t.y == null || t.w == null || t.h == null) return;
    try {
      await context.read<ApiClient>().updateTableLayout(
            t.number,
            zone: t.zone,
            x: t.x,
            y: t.y,
            w: t.w,
            h: t.h,
            shape: t.shape,
          );
      _snack('Table ${t.number} layout saved');
    } catch (e) {
      _snack('Could not save layout: $e');
    }
  }

  void _dragTable(CafeTable t, int index, DragUpdateDetails d, double canvasW,
      double canvasH) {
    final base = _rectOf(t, index);
    final nx = (base.x + d.delta.dx / canvasW * 100).clamp(0, 100 - base.w);
    final ny = (base.y + d.delta.dy / canvasH * 100).clamp(0, 100 - base.h);
    setState(() {
      _tables = [
        for (final tb in _tables)
          tb.number == t.number
              ? tb.copyWith(x: nx.round(), y: ny.round(), w: base.w, h: base.h)
              : tb
      ];
    });
  }

  Future<void> _editLayout(CafeTable t) async {
    final index = _tables.indexWhere((e) => e.number == t.number);
    final base = _rectOf(t, index < 0 ? 0 : index);
    final zoneCtrl = TextEditingController(text: t.zone);
    final xCtrl = TextEditingController(text: base.x.toString());
    final yCtrl = TextEditingController(text: base.y.toString());
    final wCtrl = TextEditingController(text: base.w.toString());
    final hCtrl = TextEditingController(text: base.h.toString());
    String shape = t.shape;

    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Arrange table ${t.number}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: zoneCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Zone',
                    hintText: 'main, terrace, ...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: shape,
                  decoration: const InputDecoration(
                    labelText: 'Shape',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'rect', child: Text('Rectangle')),
                    DropdownMenuItem(value: 'round', child: Text('Round')),
                  ],
                  onChanged: (v) => setDialogState(() => shape = v ?? shape),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _numField(xCtrl, 'X (0-100)'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _numField(yCtrl, 'Y (0-100)'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _numField(wCtrl, 'Width'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _numField(hCtrl, 'Height'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final x = int.tryParse(xCtrl.text.trim());
                final y = int.tryParse(yCtrl.text.trim());
                final w = int.tryParse(wCtrl.text.trim());
                final h = int.tryParse(hCtrl.text.trim());
                final zone = zoneCtrl.text.trim();
                if (x == null || y == null || w == null || h == null) {
                  return;
                }
                if (x < 0 ||
                    x > 100 ||
                    y < 0 ||
                    y > 100 ||
                    w < 1 ||
                    w > 100 ||
                    h < 1 ||
                    h > 100 ||
                    zone.isEmpty) {
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;

    final payload = {
      'zone': zoneCtrl.text.trim(),
      'shape': shape,
      'x': int.parse(xCtrl.text.trim()),
      'y': int.parse(yCtrl.text.trim()),
      'w': int.parse(wCtrl.text.trim()),
      'h': int.parse(hCtrl.text.trim()),
    };
    try {
      await context.read<ApiClient>().updateTableLayout(
            t.number,
            zone: payload['zone'] as String,
            shape: payload['shape'] as String,
            x: payload['x'] as int,
            y: payload['y'] as int,
            w: payload['w'] as int,
            h: payload['h'] as int,
          );
      await _load();
      _snack('Table ${t.number} layout saved');
    } catch (e) {
      _snack('Could not save layout: $e');
    }
  }

  Widget _numField(TextEditingController ctrl, String label) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _viewToggle(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          Text(
            'Tables',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          if (_floorView)
            IconButton(
              tooltip: _editMode ? 'Done editing' : 'Edit floor layout',
              icon: Icon(
                _editMode ? Icons.check : Icons.edit_outlined,
                color: _editMode ? Theme.of(context).colorScheme.primary : null,
              ),
              onPressed: () => setState(() => _editMode = !_editMode),
            ),
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                        value: false,
                        label: Text('Grid'),
                        icon: Icon(Icons.grid_view, size: 15)),
                    ButtonSegment(
                        value: true,
                        label: Text('Floor'),
                        icon: Icon(Icons.map_outlined, size: 15)),
                  ],
                  selected: {_floorView},
                  onSelectionChanged: (v) => setState(() {
                    _floorView = v.first;
                    if (!_floorView) _editMode = false;
                  }),
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: Colors.white,
                    foregroundColor:
                        Theme.of(context).colorScheme.onSurfaceVariant,
                    selectedBackgroundColor: CafePalette.coffee,
                    selectedForegroundColor: Colors.white,
                    side: BorderSide.none,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFloorEditor() {
    if (_editMode) {
      return Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              gradient: CafeGradients.espresso,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              children: [
                Icon(Icons.edit_outlined, size: 16, color: Colors.white),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Edit mode — drag a table to move it, tap to resize / change zone & shape.',
                    style: TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _floorCanvas()),
        ],
      );
    }
    return _floorCanvas();
  }

  Widget _floorCanvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cw = constraints.maxWidth;
        final ch = constraints.maxHeight;
        return Stack(
          children: [
            for (var i = 0; i < _tables.length; i++)
              _floorEntry(_tables[i], i, cw, ch),
          ],
        );
      },
    );
  }

  Positioned _floorEntry(CafeTable t, int index, double cw, double ch) {
    final rect = _rectOf(t, index);
    return Positioned(
      left: rect.x / 100 * cw,
      top: rect.y / 100 * ch,
      width: rect.w / 100 * cw,
      height: rect.h / 100 * ch,
      child: GestureDetector(
        onTap: () {
          if (_editMode) {
            _editLayout(t);
          } else {
            _showTableDetails(t);
          }
        },
        onPanUpdate: _editMode ? (d) => _dragTable(t, index, d, cw, ch) : null,
        onPanEnd: _editMode
            ? (_) {
                final fresh = _tables.firstWhere(
                  (e) => e.number == t.number,
                  orElse: () => t,
                );
                _persistLayout(fresh);
              }
            : null,
        child: _FloorEditorTile(
          table: t,
          editMode: _editMode,
        ),
      ),
    );
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

    final occupied = _tables.where((t) => t.isOccupied).length;
    _tables.sort((a, b) => int.parse(a.number).compareTo(int.parse(b.number)));

    return Scaffold(
      body: Column(
        children: [
          _viewToggle(context),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _floorView
                  ? _buildFloorEditor()
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                                color: Colors.black.withValues(alpha: 0.05)),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    CafePalette.coffee.withValues(alpha: 0.06),
                                blurRadius: 14,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: _SummaryStat(
                                  label: 'Total tables',
                                  value: '${_tables.length}',
                                  color: CafePalette.coffee,
                                  emoji: '🪑',
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 40,
                                color: Colors.black.withValues(alpha: 0.06),
                              ),
                              Expanded(
                                child: _SummaryStat(
                                  label: 'Occupied',
                                  value: '$occupied',
                                  color: CafePalette.peach,
                                  emoji: '🧾',
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 40,
                                color: Colors.black.withValues(alpha: 0.06),
                              ),
                              Expanded(
                                child: _SummaryStat(
                                  label: 'Free',
                                  value: '${_tables.length - occupied}',
                                  color: CafePalette.mint,
                                  emoji: '🍽️',
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        GridView.count(
                          crossAxisCount: 3,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          childAspectRatio: 0.84,
                          children: _tables
                              .map((t) => _TableCard(
                                    table: t,
                                    onTap: () => _showTableDetails(t),
                                  ))
                              .toList(),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addTable,
        icon: const Icon(Icons.add),
        label: const Text('Add table'),
      ),
    );
  }
}

class _TableCard extends StatelessWidget {
  final CafeTable table;
  final VoidCallback onTap;
  const _TableCard({required this.table, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final occupied = table.isOccupied;
    final accent = occupied ? CafePalette.peach : CafePalette.mint;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.55), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'TABLE',
                        style: TextStyle(
                            fontSize: 9,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade500),
                      ),
                    ),
                    Text(occupied ? '🧾' : '🍽️',
                        style: const TextStyle(fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '#${table.number}',
                  style: TextStyle(
                      fontSize: 26,
                      height: 1.0,
                      fontWeight: FontWeight.w800,
                      color:
                          occupied ? CafePalette.espresso : CafePalette.coffee),
                ),
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    occupied ? 'Occupied' : 'Free',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: occupied
                          ? const Color(0xFF9A4A2B)
                          : const Color(0xFF2F6B51),
                    ),
                  ),
                ),
                if (table.zone != 'main')
                  Text(
                    table.zone,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10, color: CafePalette.caramel),
                  ),
                if (occupied)
                  Text(
                    'Order #${table.orderId ?? '?'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey.shade500,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Floor Map Tile (owner editor) ───

class _FloorEditorTile extends StatelessWidget {
  final CafeTable table;
  final bool editMode;
  const _FloorEditorTile({required this.table, this.editMode = false});

  @override
  Widget build(BuildContext context) {
    final occupied = table.isOccupied;
    final accent = occupied ? CafePalette.peach : CafePalette.mint;
    const radius = BorderRadius.all(Radius.circular(14));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: table.isRound ? null : radius,
        shape: table.isRound ? BoxShape.circle : BoxShape.rectangle,
        border: Border.all(
          color: editMode ? CafePalette.coffee : accent.withValues(alpha: 0.6),
          width: editMode ? 2.2 : 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: (editMode ? CafePalette.coffee : accent)
                .withValues(alpha: editMode ? 0.25 : 0.18),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(occupied ? '🧾' : '🍽️',
                  style: const TextStyle(fontSize: 13)),
              Text(
                'T${table.number}',
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
              ),
              if (table.zone != 'main')
                Text(
                  table.zone,
                  style: TextStyle(fontSize: 8, color: Colors.grey.shade700),
                ),
              Container(
                margin: const EdgeInsets.only(top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  occupied ? 'Occupied' : 'Free',
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    color: occupied
                        ? const Color(0xFF9A4A2B)
                        : const Color(0xFF2F6B51),
                  ),
                ),
              ),
              if (editMode)
                const Text(
                  'drag • tap',
                  style: TextStyle(
                      fontSize: 7,
                      fontWeight: FontWeight.w700,
                      color: CafePalette.coffee),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Summary stat (owner grid header) ───

class _SummaryStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final String emoji;

  const _SummaryStat({
    required this.label,
    required this.value,
    required this.color,
    required this.emoji,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 4),
            Text(
              value,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w800, color: color),
            ),
          ],
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

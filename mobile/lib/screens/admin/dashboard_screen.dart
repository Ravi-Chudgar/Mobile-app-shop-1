import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/sales_summary.dart';
import '../../services/api_client.dart';
import '../../state/auth_state.dart';
import '../../util/money.dart';
import '../../widgets/ui_kit.dart';
import '../owner/billing_screen.dart';
import '../owner/growth_screen.dart';
import '../owner/tables_admin_screen.dart';
import 'inventory_screen.dart';
import 'menu_editor_screen.dart';
import 'orders_queue_screen.dart';

/// Warm, glanceable sales dashboard: latte-art hero with the day's headline
/// numbers, a KPI strip, quick jumps into the owner screens, and the fl_chart
/// sales/payments/best-seller panels — all on the shared coffee design kit.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _fmt = DateFormat('yyyy-MM-dd');
  DateTime _selected = DateTime.now();
  String _range = 'today'; // today | 7d | 30d
  SalesSummary? _agg; // headline figures for the selected range
  List<SalesSummary> _series = []; // chart series for the range
  bool _loading = true;
  String? _error;

  // Best-effort extras for badges/KPIs — advisory, so never fatal.
  int? _unpaid; // outstanding dues, paise
  int? _lowStock; // inventory items at/below reorder level

  bool get _isToday => _range == 'today';

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
      final date = _fmt.format(_selected);
      final days = _range == '7d'
          ? 7
          : _range == '30d'
              ? 30
              : 1;
      final from = _fmt.format(_selected.subtract(Duration(days: days - 1)));
      final results = await Future.wait([
        api.dailyReport(date),
        if (days >= 2) api.rangeReport(from, date),
      ]);
      if (!mounted) return;
      final series = days >= 2
          ? results[1] as List<SalesSummary>
          : <SalesSummary>[results[0] as SalesSummary];
      setState(() {
        _agg = _isToday ? results[0] as SalesSummary : _summarize(series);
        _series = series;
        _loading = false;
      });
      await _loadExtras(api);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadExtras(ApiClient api) async {
    int? unpaid;
    int? low;
    try {
      unpaid = (await api.fetchBilling()).unpaid;
    } catch (_) {
      // Billing summary is optional here — the dashboard still works.
    }
    try {
      low = (await api.fetchInventoryAlerts()).length;
    } catch (_) {
      // Alerts are advisory — same guard as the inventory screen.
    }
    if (!mounted) return;
    setState(() {
      _unpaid = unpaid;
      _lowStock = low;
    });
  }

  static SalesSummary _summarize(List<SalesSummary> series) {
    var gross = 0;
    var orders = 0;
    final byCat = <String, int>{};
    final byPay = <String, int>{};
    for (final s in series) {
      gross += s.grossSales;
      orders += s.orderCount;
      s.byCategory.forEach((k, v) => byCat[k] = (byCat[k] ?? 0) + v);
      s.byPayment.forEach((k, v) => byPay[k] = (byPay[k] ?? 0) + v);
    }
    return SalesSummary(
      date: '',
      orderCount: orders,
      grossSales: gross,
      byCategory: byCat,
      byPayment: byPay,
      topItems: const [],
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selected,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _selected = picked);
      _load();
    }
  }

  int? _deltaPct() {
    if (_series.length < 2) return null;
    final cur = _series.last.grossSales;
    final prev = _isToday
        ? _series[_series.length - 2].grossSales
        : _series.first.grossSales;
    if (prev <= 0) return null;
    return ((cur - prev) * 100 / prev).round();
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _RetryView(message: _error!, onRetry: _load);
    final agg = _agg!;
    final auth = context.read<AuthState>();
    final ownerName = auth.name ?? auth.username ?? 'Owner';
    final delta = _deltaPct();
    final avg =
        agg.orderCount == 0 ? 0 : (agg.grossSales / agg.orderCount).round();
    final isLive =
        _isToday && _fmt.format(_selected) == _fmt.format(DateTime.now());
    final dateLabel = DateFormat('EEEE, d MMMM y').format(_selected);

    return Stack(
      children: [
        // Soft cream-on-cream blobs keep the background lively, not loud.
        const Positioned(
            top: -50,
            right: -40,
            child: _Blob(color: CafePalette.latte, size: 190)),
        const Positioned(
            bottom: 160,
            left: -70,
            child: _Blob(color: CafePalette.caramel, size: 170)),
        RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              // ── Hero: greeting, date, headline revenue ──
              HeroBanner(
                gradient: CafeGradients.espresso,
                illustration: Align(
                  alignment: const Alignment(0.85, 0.1),
                  child: Opacity(
                    opacity: 0.18,
                    child: SizedBox(
                      width: 180,
                      height: 180,
                      child: CustomPaint(painter: LatteArtPainter()),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_greeting()}, $ownerName',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                dateLabel,
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.75),
                                    fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Change date',
                          onPressed: _pickDate,
                          icon: const Icon(Icons.calendar_month,
                              color: Colors.white, size: 22),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      isLive ? "TODAY'S REVENUE" : 'REVENUE',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2),
                    ),
                    const SizedBox(height: 4),
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: agg.grossSales.toDouble()),
                      duration: const Duration(milliseconds: 900),
                      curve: Curves.easeOutCubic,
                      builder: (_, v, __) => FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          formatMoney(v.round()),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 40,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (delta != null) _DeltaPill(delta: delta),
                        _HeroChip(label: '🧾 ${agg.orderCount} orders'),
                        if (agg.orderCount > 0)
                          _HeroChip(label: '☕ avg ${formatMoney(avg)}'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              _RangeSelector(
                value: _range,
                onChanged: (r) {
                  setState(() => _range = r);
                  _load();
                },
              ),

              // ── KPI strip ──
              SectionHeader(
                title: 'Key numbers',
                subtitle: isLive
                    ? 'Live for today'
                    : DateFormat('d MMM y').format(_selected),
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cols = constraints.maxWidth > 900 ? 3 : 2;
                  const gap = 10.0;
                  final itemW =
                      (constraints.maxWidth - gap * (cols - 1)) / cols;
                  final stats = <Widget>[
                    StatCard(
                      label: 'Orders',
                      value: '${agg.orderCount}',
                      icon: Icons.receipt_long,
                      gradient: CafeGradients.peach,
                      caption: 'tickets in range',
                    ),
                    StatCard(
                      label: 'Revenue',
                      value: formatMoney(agg.grossSales),
                      icon: Icons.payments,
                      gradient: CafeGradients.espresso,
                      caption: 'gross sales',
                    ),
                    StatCard(
                      label: 'Avg order',
                      value: formatMoney(avg),
                      icon: Icons.shopping_bag,
                      gradient: CafeGradients.mint,
                      caption: 'per ticket',
                    ),
                    if (_unpaid != null)
                      StatCard(
                        label: 'Unpaid dues',
                        value: formatMoney(_unpaid!),
                        icon: Icons.account_balance_wallet,
                        gradient: CafeGradients.berry,
                        caption:
                            _unpaid! > 0 ? 'needs collecting' : 'all settled',
                      ),
                    if (_lowStock != null && _lowStock! > 0)
                      StatCard(
                        label: 'Low stock',
                        value: '$_lowStock items',
                        icon: Icons.warning_amber,
                        gradient: CafeGradients.sunrise,
                        caption: 'at reorder level',
                      ),
                    StatCard(
                      label: 'Peak day',
                      value: _peakDay(),
                      icon: Icons.calendar_month,
                      gradient: CafeGradients.sky,
                      caption: _isToday ? 'busiest day so far' : 'busiest day',
                    ),
                  ];
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final s in stats) SizedBox(width: itemW, child: s),
                    ],
                  );
                },
              ),

              // ── Quick actions ──
              const SectionHeader(
                title: 'Quick actions',
                subtitle: 'Jump to a screen',
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cols = constraints.maxWidth > 860 ? 3 : 2;
                  const gap = 10.0;
                  final itemW =
                      (constraints.maxWidth - gap * (cols - 1)) / cols;
                  final actions = <Widget>[
                    QuickActionTile(
                      icon: Icons.table_restaurant,
                      label: 'Tables',
                      gradient: CafeGradients.espresso,
                      onTap: () => _push(const TablesAdminScreen()),
                    ),
                    QuickActionTile(
                      icon: Icons.receipt_long,
                      label: 'Orders',
                      gradient: CafeGradients.peach,
                      onTap: () => _push(const OrdersQueueScreen()),
                    ),
                    QuickActionTile(
                      icon: Icons.point_of_sale,
                      label: 'Billing',
                      gradient: CafeGradients.mint,
                      badge: (_unpaid ?? 0) > 0 ? formatMoney(_unpaid!) : null,
                      onTap: () => _push(const BillingScreen()),
                    ),
                    QuickActionTile(
                      icon: Icons.restaurant_menu,
                      label: 'Menu',
                      gradient: CafeGradients.sunrise,
                      onTap: () => _push(const MenuEditorScreen()),
                    ),
                    QuickActionTile(
                      icon: Icons.inventory_2,
                      label: 'Inventory',
                      gradient: CafeGradients.sky,
                      badge: (_lowStock ?? 0) > 0 ? '$_lowStock' : null,
                      onTap: () => _push(const InventoryScreen()),
                    ),
                    QuickActionTile(
                      icon: Icons.trending_up,
                      label: 'Growth',
                      gradient: CafeGradients.berry,
                      onTap: () => _push(const GrowthScreen()),
                    ),
                  ];
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final a in actions) SizedBox(width: itemW, child: a),
                    ],
                  );
                },
              ),

              // ── Charts ──
              _Card(
                title: 'Sales over time',
                subtitle: 'Gross sales per day',
                trailing: Icon(Icons.bar_chart_rounded,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                child:
                    SizedBox(height: 180, child: _TrendBars(series: _series)),
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final pay = agg.byPayment.isNotEmpty
                      ? _Card(
                          title: 'Payments',
                          subtitle: 'How the cafe got paid',
                          child: _PaymentDonut(byPayment: agg.byPayment))
                      : null;
                  final best = _isToday && agg.topItems.isNotEmpty
                      ? _Card(
                          title: 'Best sellers',
                          subtitle: 'Ranked by quantity sold',
                          child: Column(
                            children: [
                              for (var i = 0; i < agg.topItems.length; i++)
                                _TopSellerRow(
                                  index: i,
                                  item: agg.topItems[i],
                                  maxQty: agg.topItems
                                      .map((t) => t.qty)
                                      .fold<int>(0, (m, q) => q > m ? q : m),
                                ),
                            ],
                          ),
                        )
                      : null;
                  if (pay == null && best == null) {
                    return const SizedBox.shrink();
                  }
                  if (constraints.maxWidth < 600) {
                    return Column(
                      children: [
                        if (pay != null) pay,
                        if (pay != null && best != null)
                          const SizedBox(height: 8),
                        if (best != null) best,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (pay != null) Expanded(child: pay),
                      if (pay != null && best != null)
                        const SizedBox(width: 16),
                      if (best != null) Expanded(child: best),
                    ],
                  );
                },
              ),
              if (agg.byCategory.isNotEmpty)
                _Card(
                  title: 'By category',
                  subtitle: 'Where the revenue came from',
                  child:
                      _CategoryBars(entries: agg.byCategory.entries.toList()),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _push(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  String _peakDay() {
    if (_series.isEmpty) return '—';
    var best = _series.first;
    for (final s in _series) {
      if (s.grossSales > best.grossSales) best = s;
    }
    if (best.grossSales == 0 || best.date.isEmpty) return '—';
    final d = DateTime.tryParse(best.date);
    return d == null ? '—' : DateFormat('E').format(d);
  }
}

class _Blob extends StatelessWidget {
  final Color color;
  final double size;
  const _Blob({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.35),
      ),
    );
  }
}

class _RangeSelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _RangeSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(value: 'today', label: Text('Today')),
        ButtonSegment(value: '7d', label: Text('7 days')),
        ButtonSegment(value: '30d', label: Text('30 days')),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        backgroundColor: Colors.white,
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        selectedBackgroundColor: CafePalette.coffee,
        selectedForegroundColor: Colors.white,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}

/// Small translucent pill used on the dark hero surface.
class _HeroChip extends StatelessWidget {
  final String label;
  const _HeroChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 12)),
    );
  }
}

class _DeltaPill extends StatelessWidget {
  final int delta;
  const _DeltaPill({required this.delta});

  @override
  Widget build(BuildContext context) {
    final up = delta >= 0;
    final color = up ? const Color(0xFF15803D) : const Color(0xFFB91C1C);
    final bg = up ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              size: 13, color: color),
          const SizedBox(width: 2),
          Text('${up ? '+' : ''}$delta%',
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

/// Section header + white framed panel used for every chart block.
class _Card extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  const _Card({
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: title, subtitle: subtitle, trailing: trailing),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
            boxShadow: [
              BoxShadow(
                color: CafePalette.coffee.withValues(alpha: 0.06),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: child,
        ),
      ],
    );
  }
}

/// Warm coffee/peach/mint series shared by every chart on this screen.
const _chartColors = [
  CafePalette.peach,
  CafePalette.mint,
  CafePalette.coffee,
  CafePalette.sunshine,
  CafePalette.berry,
];

class _TrendBars extends StatelessWidget {
  final List<SalesSummary> series;
  const _TrendBars({required this.series});

  @override
  Widget build(BuildContext context) {
    final values = series.map((s) => s.grossSales.toDouble()).toList();
    final maxV = values.fold<double>(0, (m, v) => v > m ? v : m);
    final maxY = maxV == 0 ? 100.0 : maxV * 1.2;
    return BarChart(
      BarChartData(
        maxY: maxY,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
              formatMoney(rod.toY.round()),
              const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= series.length) return const SizedBox();
                final date = DateTime.tryParse(series[i].date);
                final label =
                    date == null ? '' : DateFormat('d/M').format(date);
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(label, style: const TextStyle(fontSize: 10)),
                );
              },
            ),
          ),
        ),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        barGroups: [
          for (var i = 0; i < values.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: values[i],
                  width: 18,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      _chartColors[i % _chartColors.length]
                          .withValues(alpha: 0.95),
                      _chartColors[i % _chartColors.length]
                          .withValues(alpha: 0.35),
                    ],
                  ),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(8)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

String _payEmoji(String m) {
  switch (m) {
    case 'cash':
      return '💵';
    case 'card':
      return '💳';
    case 'upi':
      return '📲';
    case 'gpay':
      return '🔷';
    default:
      return '💰';
  }
}

class _PaymentDonut extends StatelessWidget {
  final Map<String, int> byPayment;
  const _PaymentDonut({required this.byPayment});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = byPayment.entries.toList();
    final total = entries.fold<int>(0, (s, e) => s + e.value);
    return Row(
      children: [
        SizedBox(
          width: 130,
          height: 130,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 44,
                  startDegreeOffset: -90,
                  sections: [
                    for (var i = 0; i < entries.length; i++)
                      PieChartSectionData(
                        value: entries[i].value.toDouble(),
                        color: _chartColors[i % _chartColors.length],
                        radius: 42,
                        showTitle: false,
                      ),
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(formatMoney(total),
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800)),
                  ),
                  Text('sales',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < entries.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Text(_payEmoji(entries[i].key),
                          style: const TextStyle(fontSize: 14)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_pretty(entries[i].key),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _chartColors[i % _chartColors.length],
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(formatMoney(entries[i].value),
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TopSellerRow extends StatelessWidget {
  final int index;
  final TopItem item;
  final int maxQty;
  const _TopSellerRow({
    required this.index,
    required this.item,
    required this.maxQty,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = maxQty == 0 ? 0.0 : item.qty / maxQty;
    final art = CafeGradients.forSeed(item.name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: art,
              borderRadius: BorderRadius.circular(13),
              boxShadow: [
                BoxShadow(
                  color: art.colors.first.withValues(alpha: 0.30),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(dishEmoji(item.name),
                style: const TextStyle(fontSize: 19)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('#${index + 1}',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurfaceVariant)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                    Text(formatMoney(item.revenue),
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 6,
                          color: art.colors.first,
                          backgroundColor: CafePalette.latte,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${item.qty} sold',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryBars extends StatelessWidget {
  final List<MapEntry<String, int>> entries;
  const _CategoryBars({required this.entries});

  @override
  Widget build(BuildContext context) {
    final maxVal = entries.fold<int>(0, (m, e) => e.value > m ? e.value : m);
    return Column(
      children: [
        for (var i = 0; i < entries.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(
                    width: 90,
                    child: Text(entries[i].key.replaceAll('_', ' ').trim(),
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w500))),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: maxVal == 0 ? 0 : entries[i].value / maxVal,
                      minHeight: 10,
                      backgroundColor: CafePalette.latte,
                      color: _chartColors[i % _chartColors.length],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                    width: 70,
                    child: Text(formatMoney(entries[i].value),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600))),
              ],
            ),
          ),
      ],
    );
  }
}

class _RetryView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _RetryView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.coffee_outlined,
              size: 44, color: CafePalette.caramel),
          const SizedBox(height: 10),
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

String _pretty(String s) => s
    .replaceAll('_', ' ')
    .split(' ')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

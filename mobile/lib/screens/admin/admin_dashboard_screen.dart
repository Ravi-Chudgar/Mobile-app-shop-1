import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../../state/auth_state.dart';
import '../../util/money.dart';
import '../../widgets/credentials_share.dart';
import '../../widgets/ui_kit.dart';
import 'create_cafe_screen.dart';

/// Cross-cafe dashboard: every registered cafe with its owner/legal details and
/// the current month's profit & loss. "Manage" swaps the session into that
/// cafe's owner mode (RootGate then shows the owner shell); "Add cafe" opens
/// the creation form.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _cafes = [];
  String? _actingSlug; // the cafe whose "Manage" button shows a spinner

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
      final api = context.read<ApiClient>();
      final data = await api.platformListCafes();
      final cafes = (data['cafes'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (!mounted) return;
      setState(() {
        _cafes = cafes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _manage(Map<String, dynamic> cafe) async {
    final slug = cafe['slug'] as String? ?? '';
    if (slug.isEmpty) return;
    setState(() => _actingSlug = slug);
    try {
      // On success RootGate rebuilds into the owner shell, so we never reset
      // _actingSlug — this whole screen is replaced.
      await context
          .read<AuthState>()
          .actAsOwner(slug, cafeName: cafe['display_name'] as String?);
    } catch (e) {
      if (!mounted) return;
      setState(() => _actingSlug = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open $slug: $e')));
    }
  }

  Future<void> _addCafe() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateCafeScreen()),
    );
    if (created == true) _load();
  }

  /// Opens the share sheet with this cafe's owner login. The password can't be
  /// re-shown here (only hashed server-side), so the card refers back to the
  /// password chosen when the cafe was created.
  Future<void> _shareLogin(Map<String, dynamic> cafe) async {
    final name = (cafe['display_name'] as String? ?? '').isNotEmpty
        ? cafe['display_name'] as String
        : (cafe['slug'] as String? ?? '');
    final message = credentialsMessage(
      cafeName: name,
      cafeCode: cafe['slug'] as String? ?? '',
      username: cafe['owner_username'] as String? ?? '',
      password: null,
    );
    await shareMessage(context, message, title: 'Cafe POS login — $name');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _MessageView(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't load cafes",
        message: _error!,
        onRetry: _load,
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCafe,
        icon: const Icon(Icons.add_business_rounded),
        label: const Text('Add cafe'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _cafes.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  _MessageView(
                    icon: Icons.storefront_outlined,
                    title: 'No cafes yet',
                    message: 'Tap “Add cafe” to register the first one.',
                  ),
                ],
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                itemCount: _cafes.length,
                itemBuilder: (context, i) => _CafeCard(
                  cafe: _cafes[i],
                  busy: _actingSlug == _cafes[i]['slug'],
                  onManage: () => _manage(_cafes[i]),
                  onShare: () => _shareLogin(_cafes[i]),
                ),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _CafeCard extends StatelessWidget {
  const _CafeCard({
    required this.cafe,
    required this.busy,
    required this.onManage,
    required this.onShare,
  });

  final Map<String, dynamic> cafe;
  final bool busy;
  final VoidCallback onManage;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pnl = Map<String, dynamic>.from(cafe['pnl'] as Map? ?? {});
    final net = (pnl['net_profit'] as num?)?.toInt();
    final rev = (pnl['revenue'] as num?)?.toInt();
    final orders = (pnl['total_orders'] as num?)?.toInt();
    final inProfit = (pnl['in_profit'] as bool?) ?? true;

    String s(String k) => '${cafe[k] ?? ''}';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const IconChip(
                  icon: Icons.storefront_rounded,
                  gradient: CafeGradients.coffee,
                  size: 40,
                  iconSize: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s('display_name').isEmpty
                            ? s('slug')
                            : s('display_name'),
                        style: text.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        'code: ${s('slug')}',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (s('owner_name').isNotEmpty) _kv('Owner', s('owner_name')),
            if (s('gstin').isNotEmpty) _kv('GSTIN', s('gstin')),
            if (s('pan').isNotEmpty) _kv('PAN', s('pan')),
            if (s('shop_license').isNotEmpty) _kv('Licence', s('shop_license')),
            if (s('owner_username').isNotEmpty)
              _kv('Login', s('owner_username')),
            const SizedBox(height: 12),
            Row(
              children: [
                _plTile(context, 'Revenue',
                    rev != null ? formatMoney(rev) : '—', scheme.primary),
                _plTile(
                    context,
                    'Net profit',
                    net != null ? formatMoney(net) : '—',
                    inProfit ? const Color(0xFF2E7D32) : scheme.error),
                _plTile(context, 'Orders', orders != null ? '$orders' : '—',
                    scheme.onSurface),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : onManage,
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.tune_rounded, size: 18),
                    label: Text(busy ? 'Opening…' : 'Manage this cafe'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.share_rounded, size: 16),
                  label: const Text('Login'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 74,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(fontSize: 12.5, height: 1.3)),
            ),
          ],
        ),
      );

  Widget _plTile(
          BuildContext context, String label, String value, Color color) =>
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    )),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      );
}

// ---------------------------------------------------------------------------

class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.icon,
    required this.title,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: text.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

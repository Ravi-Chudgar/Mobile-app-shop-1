import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../../state/auth_state.dart';
import '../../widgets/shell_app_bar.dart';
import '../../widgets/ui_kit.dart';
import '../admin/dashboard_screen.dart';
import '../admin/inventory_screen.dart';
import '../staff/ask_screen.dart';
import '../admin/menu_editor_screen.dart';
import '../admin/orders_queue_screen.dart';
import 'billing_screen.dart';
import 'cafe_profile_screen.dart';
import 'exports_screen.dart';
import 'printer_settings_screen.dart';
import 'reports_screen.dart';
import 'staff_screen.dart';
import 'tables_admin_screen.dart';
import 'growth_screen.dart';
import 'vendor_message_screen.dart';

/// Owner container with bottom navigation:
/// 5 main tabs + "More" overflow menu for less-used screens.
class OwnerShell extends StatefulWidget {
  const OwnerShell({super.key});

  @override
  State<OwnerShell> createState() => _OwnerShellState();
}

class _OwnerShellState extends State<OwnerShell> {
  int _index = 0;

  // Show the first-time setup wizard at most once per app session, and only
  // when the cafe has no business details yet (no GST/PAN/licence/owner set).
  static bool _setupPrompted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptSetup());
  }

  Future<void> _maybePromptSetup() async {
    if (_setupPrompted || !mounted) return;
    _setupPrompted = true;
    try {
      final api = context.read<ApiClient>();
      final p = await api.getCafeProfile();
      final unconfigured =
          '${p['gstin'] ?? ''}'.isEmpty &&
          '${p['pan'] ?? ''}'.isEmpty &&
          '${p['shop_license'] ?? ''}'.isEmpty &&
          '${p['owner_name'] ?? ''}'.isEmpty;
      if (!unconfigured || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const CafeSetupWizard(),
        ),
      );
    } catch (_) {
      // Offline or unknown — never block the owner on setup.
    }
  }

  static const _titles = [
    'Dashboard',
    'Orders',
    'Tables',
    'Billing',
    'Vendors',
  ];

  final _pages = const [
    DashboardScreen(),
    OrdersQueueScreen(),
    TablesAdminScreen(),
    BillingScreen(),
    VendorMessageScreen(),
  ];

  void _openMoreMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.8,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFEDE4DA),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  IconChip(
                    icon: Icons.more_horiz_rounded,
                    gradient: CafeGradients.coffee,
                    size: 40,
                    iconSize: 20,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'More',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Reports, growth, exports & team',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF8A6A52),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  _MoreTile(
                    icon: Icons.assessment_outlined,
                    selectedIcon: Icons.assessment,
                    title: 'Reports',
                    subtitle: 'Sales analytics & P&L',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ReportsScreen()),
                      );
                    },
                  ),
                  _MoreTile(
                    icon: Icons.trending_up_outlined,
                    selectedIcon: Icons.trending_up,
                    title: 'Growth',
                    subtitle: 'Loyalty, delivery orders & table QRs',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const GrowthScreen()),
                      );
                    },
                  ),
                  _MoreTile(
                    icon: Icons.file_upload_outlined,
                    selectedIcon: Icons.file_upload,
                    title: 'Exports',
                    subtitle: 'Tally XML/CSV & GSTR-1/GSTR-3B',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ExportsScreen()),
                      );
                    },
                  ),
                  _MoreTile(
                    icon: Icons.print_outlined,
                    selectedIcon: Icons.print,
                    title: 'Printers',
                    subtitle: 'Network · USB · Bluetooth',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const PrinterSettingsScreen()),
                      );
                    },
                  ),
                  _MoreTile(
                    icon: Icons.people_outline,
                    selectedIcon: Icons.people,
                    title: 'Staff',
                    subtitle: 'Manage team members',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const StaffScreen()),
                      );
                    },
                  ),
                  _MoreTile(
                    icon: Icons.restaurant_menu_outlined,
                    selectedIcon: Icons.restaurant_menu,
                    title: 'Menu',
                    subtitle: 'Edit menu items & prices',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const MenuEditorScreen()),
                      );
                    },
                  ),
                  _MoreTile(
                    icon: Icons.storefront_outlined,
                    selectedIcon: Icons.storefront,
                    title: 'Cafe Profile',
                    subtitle: 'Name, GST, PAN & licence on bills',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const CafeProfileScreen()),
                      );
                    },
                  ),
                  _MoreTile(
                    icon: Icons.inventory_outlined,
                    selectedIcon: Icons.inventory,
                    title: 'Inventory',
                    subtitle: 'Stock tracking',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const InventoryScreen()),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthState>();
    final name = auth.name ?? auth.username ?? 'Owner';
    return Scaffold(
      appBar: ShellAppBar(
        title: _titles[_index],
        subtitle: shellDateLabel(),
        userName: name,
        onLogout: () => context.read<AuthState>().logout(),
        onAsk: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const AskScreen())),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_horiz),
            tooltip: 'More',
            onPressed: _openMoreMenu,
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Sales',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Orders',
          ),
          NavigationDestination(
            icon: Icon(Icons.table_restaurant_outlined),
            selectedIcon: Icon(Icons.table_restaurant),
            label: 'Tables',
          ),
          NavigationDestination(
            icon: Icon(Icons.point_of_sale_outlined),
            selectedIcon: Icon(Icons.point_of_sale),
            label: 'Billing',
          ),
          NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: 'Vendors',
          ),
        ],
      ),
    );
  }
}

class _MoreTile extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MoreTile({
    required this.icon,
    required this.selectedIcon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              IconChip(
                icon: icon,
                gradient: CafeGradients.forSeed(title),
                size: 40,
                iconSize: 19,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: text.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(subtitle,
                        style: text.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

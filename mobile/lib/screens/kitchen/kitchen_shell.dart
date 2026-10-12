import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_state.dart';
import '../../widgets/shell_app_bar.dart';
import '../staff/ask_screen.dart';
import 'kitchen_display_screen.dart';

/// Kitchen display shell — shows orders for kitchen staff.
class KitchenShell extends StatefulWidget {
  const KitchenShell({super.key});

  @override
  State<KitchenShell> createState() => _KitchenShellState();
}

class _KitchenShellState extends State<KitchenShell> {
  int _index = 0;

  static const _titles = [
    'Kitchen Orders',
    'Completed',
  ];

  final _pages = const [
    KitchenDisplayScreen(showCompleted: false),
    KitchenDisplayScreen(showCompleted: true),
  ];

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthState>();
    final name = auth.name ?? auth.username ?? 'Kitchen';
    return Scaffold(
      appBar: ShellAppBar(
        title: _titles[_index],
        subtitle: shellDateLabel(),
        userName: name,
        onLogout: () => context.read<AuthState>().logout(),
        onAsk: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const AskScreen())),
      ),
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.kitchen_outlined),
            selectedIcon: Icon(Icons.kitchen),
            label: 'Active',
          ),
          NavigationDestination(
            icon: Icon(Icons.check_circle_outline),
            selectedIcon: Icon(Icons.check_circle),
            label: 'Ready',
          ),
        ],
      ),
    );
  }
}

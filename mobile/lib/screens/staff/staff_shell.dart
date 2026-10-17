import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_state.dart';
import '../../widgets/shell_app_bar.dart';
import 'ask_screen.dart';
import 'shift_screen.dart';
import 'staff_history_screen.dart';
import 'staff_orders_screen.dart';
import 'tables_grid_screen.dart';

/// Staff container: pick a table to take an order, view the shared order
/// queue, browse this staff member's own order history, or clock the shift
/// in/out (see [ShiftScreen]).
class StaffShell extends StatefulWidget {
  const StaffShell({super.key});

  @override
  State<StaffShell> createState() => _StaffShellState();
}

class _StaffShellState extends State<StaffShell> {
  int _index = 0;
  static const _titles = ['Tables', 'Order Queue', 'History', 'Shift'];
  final _pages = const [
    TablesGridScreen(),
    StaffOrdersScreen(),
    StaffHistoryScreen(),
    ShiftScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthState>();
    final name = auth.name ?? auth.username ?? 'Staff';
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
              icon: Icon(Icons.table_restaurant_outlined),
              selectedIcon: Icon(Icons.table_restaurant),
              label: 'Tables'),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'Orders'),
          NavigationDestination(
              icon: Icon(Icons.history_outlined),
              selectedIcon: Icon(Icons.history),
              label: 'History'),
          NavigationDestination(
              icon: Icon(Icons.access_time_outlined),
              selectedIcon: Icon(Icons.access_time),
              label: 'Shift'),
        ],
      ),
    );
  }
}

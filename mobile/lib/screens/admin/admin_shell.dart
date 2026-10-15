import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_state.dart';
import '../../widgets/shell_app_bar.dart';
import 'admin_dashboard_screen.dart';

/// Platform-admin container. The signed-in admin sees every cafe and can open
/// any of them in full owner mode, or add a new cafe.
class AdminShell extends StatelessWidget {
  const AdminShell({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    return Scaffold(
      appBar: ShellAppBar(
        title: 'Platform Admin',
        subtitle: shellDateLabel(),
        userName: auth.name ?? auth.username ?? 'Admin',
        onLogout: () => context.read<AuthState>().logout(),
      ),
      body: const AdminDashboardScreen(),
    );
  }
}

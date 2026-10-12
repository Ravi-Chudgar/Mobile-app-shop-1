import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/staff_member.dart';
import '../../services/api_client.dart';

/// Owner view: approve/remove staff and see who's present (last login).
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  List<StaffMember> _staff = [];
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
      final staff = await context.read<ApiClient>().fetchStaff();
      if (!mounted) return;
      setState(() {
        _staff = staff;
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

  Future<void> _approve(StaffMember s) async {
    try {
      await context.read<ApiClient>().approveStaff(s.username);
      await _load();
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _remove(StaffMember s) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Remove ${s.name}?'),
        content: const Text('They will no longer be able to log in.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;
    if (!mounted) return;
    try {
      await context.read<ApiClient>().removeStaff(s.username);
      await _load();
    } catch (e) {
      _snack('$e');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  String _present(StaffMember s) {
    if (s.lastLogin == null) return 'Never logged in';
    final dt = DateTime.tryParse(s.lastLogin!)?.toLocal();
    if (dt == null) return 'Last login unknown';
    final now = DateTime.now();
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return sameDay
        ? 'Present today • $hh:$mm'
        : 'Last login ${dt.day}/${dt.month} $hh:$mm';
  }

  Future<void> _addStaffDialog() async {
    final user = TextEditingController();
    final pass = TextEditingController();
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add staff'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Full name')),
            TextField(
                controller: user,
                decoration: const InputDecoration(labelText: 'Username')),
            TextField(
                controller: pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add')),
        ],
      ),
    );
    if (ok == true && user.text.trim().isNotEmpty) {
      if (!mounted) return;
      try {
        await context
            .read<ApiClient>()
            .createStaff(user.text.trim(), pass.text, name.text.trim());
        await _load();
      } catch (e) {
        _snack('$e');
      }
    }
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
    final pending = _staff.where((s) => s.isPending).toList();
    final active = _staff.where((s) => !s.isPending).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Staff')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (pending.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
                child: Text('Pending approval',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ...pending.map((s) => Card(
                    color: const Color(0xFFFFF4E5),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.hourglass_top, color: Colors.orange),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                Text('@${s.username}',
                                    style: const TextStyle(
                                        fontSize: 12, color: Colors.black54)),
                              ],
                            ),
                          ),
                          FilledButton(
                            onPressed: () => _approve(s),
                            child: const Text('Approve'),
                          ),
                        ],
                      ),
                    ),
                  )),
              const SizedBox(height: 12),
            ],
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
              child:
                  Text('Team', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ...active.map((s) => Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Text(
                          s.name.isNotEmpty ? s.name[0].toUpperCase() : '?'),
                    ),
                    title: Row(
                      children: [
                        Text(s.name),
                        const SizedBox(width: 8),
                        if (s.isOwner)
                          const Chip(
                            label:
                                Text('Owner', style: TextStyle(fontSize: 11)),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    subtitle: Text('@${s.username} • ${_present(s)}'),
                    trailing: s.isOwner
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.person_remove_outlined,
                                color: Colors.red),
                            onPressed: () => _remove(s),
                          ),
                  ),
                )),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addStaffDialog,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add staff'),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';

/// Staff shift screen: clock in when the shift starts, clock out when it ends.
///
/// The record is deliberately one-way. Once the server stores a clock-in it
/// can never be edited or redone (the API has no such endpoint and answers
/// 409 on any second attempt), so this screen only ever offers the one
/// action that is still possible: Clock in — then Clock out. After that the
/// day's record is closed and read-only.
class ShiftScreen extends StatefulWidget {
  const ShiftScreen({super.key});

  @override
  State<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends State<ShiftScreen> {
  Map<String, dynamic>? _record;
  bool _loading = true;
  bool _busy = false;

  bool get _clockedIn => _record?['status'] == 'in';
  bool get _clockedOut => _record?['status'] == 'out';

  @override
  void initState() {
    super.initState();
    // Restore today's state (survives app restarts / re-logins).
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final record = await context.read<ApiClient>().attendanceMe();
      if (!mounted) return;
      setState(() {
        _record = record;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage('$e');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _clockIn() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final record = await context.read<ApiClient>().clockIn();
      if (!mounted) return;
      setState(() {
        _record = record;
        _busy = false;
      });
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
          content: Text('Clocked in at ${record['clock_in_local']}')));
    } on ApiException catch (e) {
      // Most likely 409: another tap (or another device) already clocked in.
      // Surface the server's message and resync so the locked state shows.
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      unawaited(_refresh());
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _confirmClockOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clock out now?'),
        content: const Text(
            'This closes your shift for today. A recorded clock-out cannot '
            'be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay clocked in'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clock out'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _clockOut();
  }

  Future<void> _clockOut() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final record = await context.read<ApiClient>().clockOut();
      if (!mounted) return;
      setState(() {
        _record = record;
        _busy = false;
      });
      messenger.hideCurrentSnackBar();
      messenger
          .showSnackBar(const SnackBar(content: Text('Shift closed — see you!')));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      unawaited(_refresh());
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: _loading
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              : Card(
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(child: _statusIcon(scheme)),
                        const SizedBox(height: 12),
                        Center(child: _statusTitle(text, scheme)),
                        const SizedBox(height: 6),
                        Center(child: _statusDetail(text, scheme)),
                        const SizedBox(height: 20),
                        ..._actions(),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _statusIcon(ColorScheme scheme) {
    if (_clockedOut) {
      return Icon(Icons.event_available_rounded,
          size: 44, color: scheme.primary);
    }
    if (_clockedIn) {
      return const Icon(Icons.check_circle_rounded,
          size: 44, color: Colors.green);
    }
    return Icon(Icons.access_time_filled_rounded,
        size: 44, color: scheme.primary);
  }

  Widget _statusTitle(TextTheme text, ColorScheme scheme) {
    if (_clockedOut) return const Text('Shift complete');
    if (_clockedIn) {
      return Text('Clocked in at ${_record?['clock_in_local'] ?? ''}');
    }
    return const Text("You're not clocked in");
  }

  Widget _statusDetail(TextTheme text, ColorScheme scheme) {
    if (_clockedOut) {
      final inAt = _record?['clock_in_local'] ?? '?';
      final outAt = _record?['clock_out_local'] ?? '?';
      return Text(
        'In $inAt  →  Out $outAt',
        style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        textAlign: TextAlign.center,
      );
    }
    if (_clockedIn) {
      return Text(
        'Your start time is locked — it cannot be edited or redone.',
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        textAlign: TextAlign.center,
      );
    }
    return Text(
      'Tap Clock in when your shift starts. Your start time is recorded '
      "for today and can't be changed.",
      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      textAlign: TextAlign.center,
    );
  }

  List<Widget> _actions() {
    // Nothing to do once the day's record is closed — deliberately no
    // re-clock-in button: the server would refuse it anyway.
    if (_clockedOut) return const [];
    if (_clockedIn) {
      return [
        OutlinedButton.icon(
          onPressed: _busy ? null : _confirmClockOut,
          icon: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.logout_rounded),
          label: const Text('Clock out'),
        ),
      ];
    }
    return [
      FilledButton.icon(
        onPressed: _busy ? null : _clockIn,
        icon: _busy
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.login_rounded),
        label: Text(_busy ? 'Clocking in…' : 'Clock in'),
      ),
    ];
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/ask_result.dart';
import '../../services/api_client.dart';

/// Chat-style front end for the agentic assistant (POST /ask). Answers can
/// take ~20 s — the local LLM thinks in single digits of tokens per second —
/// so the busy state is explicit and previous turns stay visible.
///
/// When the agent proposes a change (free a table, advance an order) nothing
/// happens until the user confirms; confirming calls /ask/execute.
class AskScreen extends StatefulWidget {
  const AskScreen({super.key});

  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _Turn {
  final String question;
  String? answer;
  PendingAction? pending;
  final bool isNote;

  _Turn({required this.question, this.answer, this.isNote = false});
}

class _AskScreenState extends State<AskScreen> {
  final _question = TextEditingController();
  final _scroll = ScrollController();
  final List<_Turn> _turns = [];
  bool _busy = false;

  static const _suggestions = [
    'Which items sold the most this week?',
    'Which tables are busy?',
    'Show me today\'s pending orders',
    'Free table 4',
  ];

  @override
  void dispose() {
    _question.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _question.text).trim();
    if (text.isEmpty || _busy) return;
    _question.clear();
    setState(() {
      _busy = true;
      _turns.add(_Turn(question: text));
    });
    _bump();

    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await context.read<ApiClient>().askQuestion(text);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _turns.last
          ..answer = result.answer
          ..pending = result.pendingAction;
      });
      _bump();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _turns.last.answer = '$e';
      });
      _bump();
      messenger.showSnackBar(const SnackBar(
          content: Text('Assistant unreachable — is Ollama running?')));
    }
  }

  Future<void> _confirm(PendingAction action) async {
    final api = context.read<ApiClient>();
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm action'),
        content: Text('${action.label}\n\nThis will be executed now.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Record the decision in the transcript either way.
    setState(() => _turns.add(_Turn(question: action.label, isNote: true)));
    _bump();
    try {
      final result = await api.executeAction(action.action, action.args);
      if (!mounted) return;
      setState(() => _turns.add(_Turn(
          question: 'Done',
          answer: '✓ ${result['status'] ?? result['number'] ?? 'completed'}',
          isNote: true)));
      _bump();
      messenger.showSnackBar(SnackBar(content: Text('${action.label} — done')));
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _turns.add(_Turn(question: 'Failed', answer: '$e', isNote: true)));
      _bump();
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _decline(PendingAction action) {
    setState(() => _turns.add(
        _Turn(question: action.label, answer: 'Cancelled.', isNote: true)));
    _bump();
  }

  void _bump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ask the assistant')),
      body: Column(
        children: [
          Expanded(
            child: _turns.isEmpty ? _empty(context) : _transcript(context),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _question,
                      enabled: !_busy,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'e.g. what sold best today?',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Ask',
                    onPressed: _busy ? null : () => _send(),
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome,
                size: 40, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            const Text('Ask about orders, tables, menu or sales.'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final s in _suggestions)
                  ActionChip(
                    label: Text(s),
                    onPressed: _busy ? null : () => _send(s),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _transcript(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      itemCount: _turns.length + (_busy ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == _turns.length) {
          return const Align(
            alignment: Alignment.centerLeft,
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text('Thinking… this can take ~20 seconds'),
                  ],
                ),
              ),
            ),
          );
        }
        final turn = _turns[i];
        if (turn.isNote) {
          return Align(
            alignment: Alignment.center,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                  '${turn.question}${turn.answer == null ? '' : ' • ${turn.answer}'}',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                constraints: const BoxConstraints(maxWidth: 320),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(turn.question),
              ),
            ),
            if (turn.answer != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  constraints: const BoxConstraints(maxWidth: 340),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(turn.answer!),
                ),
              ),
            if (turn.pending != null)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                color: scheme.tertiaryContainer.withValues(alpha: 0.5),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.touch_app_rounded,
                              size: 18, color: scheme.tertiary),
                          const SizedBox(width: 8),
                          Expanded(child: Text(turn.pending!.label)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                              onPressed: () => _decline(turn.pending!),
                              child: const Text('Cancel')),
                          const SizedBox(width: 8),
                          FilledButton(
                              onPressed: () => _confirm(turn.pending!),
                              child: const Text('Confirm')),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// Builds the plain-text login card a platform admin sends to a cafe owner.
///
/// [password] is only known right after the cafe is created — the backend
/// never returns a stored password. For an older cafe pass `null` and the
/// message simply refers back to the password chosen at creation time.
String credentialsMessage({
  required String cafeName,
  required String cafeCode,
  required String username,
  String? password,
}) {
  final b = StringBuffer()
    ..writeln('Cafe POS login — $cafeName')
    ..writeln('Username: $username');
  if (password != null && password.isNotEmpty) {
    b.writeln('Password: $password');
  } else {
    b.writeln('Password: (set when this cafe was created)');
  }
  b
    ..writeln('Cafe code: $cafeCode')
    ..writeln('')
    ..writeln('Open the Cafe POS app, enter Username + Password, and type the '
        'Cafe code in the “cafe code” box.');
  return b.toString().trimRight();
}

/// Opens the phone's native share sheet with [message].
Future<void> shareMessage(
  BuildContext context,
  String message, {
  String title = 'Cafe POS login',
}) async {
  try {
    await SharePlus.instance
        .share(ShareParams(text: message, title: title));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open the share sheet: $e')),
    );
  }
}

/// Copies [message] to the clipboard and confirms it with a snackbar.
Future<void> copyMessage(BuildContext context, String message) async {
  await Clipboard.setData(ClipboardData(text: message));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(content: Text('Copied — paste it into any chat app')),
    );
}

/// A card showing one cafe's owner login (username + password + cafe code)
/// with **Share** (native share sheet) and **Copy** (clipboard) buttons.
///
/// [password] is optional: pass it only when it was just created; older cafes
/// never expose a stored password, so leave it `null`.
class CredentialsCard extends StatelessWidget {
  const CredentialsCard({
    super.key,
    required this.cafeName,
    required this.cafeCode,
    required this.username,
    this.password,
  });

  final String cafeName;
  final String cafeCode;
  final String username;
  final String? password;

  String get _message => credentialsMessage(
        cafeName: cafeName,
        cafeCode: cafeCode,
        username: username,
        password: password,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Card(
      margin: EdgeInsets.zero,
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
                Icon(Icons.key_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Owner login',
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _row(context, 'Username', username),
            _row(context, 'Password',
                (password != null && password!.isNotEmpty)
                    ? password!
                    : '(set when this cafe was created)'),
            _row(context, 'Cafe code', cafeCode),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => shareMessage(context, _message,
                        title: 'Cafe POS login — $cafeName'),
                    icon: const Icon(Icons.share_rounded, size: 18),
                    label: const Text('Share'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => copyMessage(context, _message),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copy'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

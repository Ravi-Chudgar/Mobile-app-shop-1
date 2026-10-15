import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../../widgets/credentials_share.dart';

/// Register a new cafe together with its owner account (platform admin only).
/// On success the route pops with `true` so the dashboard refreshes.
class CreateCafeScreen extends StatefulWidget {
  const CreateCafeScreen({super.key});

  @override
  State<CreateCafeScreen> createState() => _CreateCafeScreenState();
}

class _CreateCafeScreenState extends State<CreateCafeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _scroll = ScrollController();

  final _slug = TextEditingController();
  final _name = TextEditingController();
  final _ownerName = TextEditingController();
  final _ownerUser = TextEditingController();
  final _ownerPass = TextEditingController();
  final _ownerPass2 = TextEditingController(); // confirm-password
  final _gstin = TextEditingController();
  final _pan = TextEditingController();
  final _license = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();

  bool _saving = false;

  /// Shared show/hide toggle for both password fields.
  bool _obscurePass = true;

  /// Set once the cafe exists: the credentials are shown (and shareable) here,
  /// because this is the only moment the plaintext password is known — the
  /// backend never returns a stored password afterwards.
  Map<String, String>? _created;

  @override
  void dispose() {
    for (final c in [
      _slug, _name, _ownerName, _ownerUser, _ownerPass, _ownerPass2,
      _gstin, _pan, _license, _address, _phone,
    ]) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  String? _required(String? v, [int min = 1, String? label]) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return '${label ?? 'This field'} is required';
    if (s.length < min) return '${label ?? 'This field'} must be at least $min characters';
    return null;
  }

  // ---- field validators (all shown live via AutovalidateMode.onUserInteraction)

  String? _validateSlug(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Cafe code is required';
    if (s.length < 2) return 'Cafe code must be at least 2 characters';
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s)) {
      return 'Cafe code: letters, numbers, - and _ only (no spaces)';
    }
    return null;
  }

  String? _validateUsername(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Owner username is required';
    if (s.length < 3) return 'Owner username must be at least 3 characters';
    if (!RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(s)) {
      return 'Username: letters, numbers, . and _ only (no spaces)';
    }
    return null;
  }

  String? _validatePassword(String? v) {
    final s = v ?? '';
    if (s.isEmpty) return 'Owner password is required';
    if (s.length < 6) return 'Owner password must be at least 6 characters';
    return null;
  }

  String? _validateConfirm(String? v) {
    if ((v ?? '').isEmpty) return 'Please re-enter the password';
    if (v != _ownerPass.text) return "Passwords don't match";
    return null;
  }

  // Optional business-detail fields: only checked when filled in, so a cafe
  // that has no GSTIN yet can still be created.
  String? _validatePhone(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return null;
    if (!RegExp(r'^[0-9+\-() ]{7,16}$').hasMatch(s)) {
      return 'Enter a valid phone number';
    }
    return null;
  }

  String? _validateGstin(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return null;
    if (!RegExp(r'^[0-9A-Za-z]{15}$').hasMatch(s)) {
      return 'GSTIN must be 15 characters';
    }
    return null;
  }

  String? _validatePan(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return null;
    if (!RegExp(r'^[A-Za-z]{5}[0-9]{4}[A-Za-z]$').hasMatch(s)) {
      return 'PAN must look like ABCDE1234F';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final api = context.read<ApiClient>();
      await api.platformCreateCafe({
        'slug': _slug.text.trim().toLowerCase(),
        'display_name': _name.text.trim(),
        'owner_name': _ownerName.text.trim(),
        'owner_username': _ownerUser.text.trim().toLowerCase(),
        'owner_password': _ownerPass.text,
        'gstin': _gstin.text.trim(),
        'pan': _pan.text.trim(),
        'shop_license': _license.text.trim(),
        'address': _address.text.trim(),
        'phone': _phone.text.trim(),
      });
      if (!mounted) return;
      // Keep the screen open on a success panel with the login details to hand
      // to the owner (Share / Copy). "Done" pops with `true` so the dashboard
      // refreshes.
      setState(() {
        _saving = false;
        _created = {
          'cafeName': _name.text.trim(),
          'cafeCode': _slug.text.trim().toLowerCase(),
          'username': _ownerUser.text.trim().toLowerCase(),
          'password': _ownerPass.text,
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
      // Bring the form back to the top on a validation error.
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final created = _created;
    if (created != null) return _successView(context, created);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Add cafe')),
      body: Form(
        key: _formKey,
        // Errors show up as the user types, not only after "Create cafe".
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Text('Cafe', style: text.titleSmall),
            const SizedBox(height: 8),
            TextFormField(
              controller: _slug,
              decoration: const InputDecoration(
                labelText: 'Cafe code *',
                hintText: 'e.g. chaitime (used to log in)',
              ),
              textInputAction: TextInputAction.next,
              validator: _validateSlug,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Cafe name *'),
              textInputAction: TextInputAction.next,
              validator: (v) => _required(v, 2, 'Cafe name'),
            ),
            const SizedBox(height: 20),
            Text('Owner login', style: text.titleSmall),
            const SizedBox(height: 8),
            TextFormField(
              controller: _ownerUser,
              decoration: const InputDecoration(
                labelText: 'Owner username *',
                hintText: 'min 3 characters',
              ),
              textInputAction: TextInputAction.next,
              validator: _validateUsername,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _ownerPass,
              decoration: InputDecoration(
                labelText: 'Owner password *',
                hintText: 'min 6 characters',
                suffixIcon: IconButton(
                  icon: Icon(_obscurePass
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded),
                  tooltip: _obscurePass ? 'Show password' : 'Hide password',
                  onPressed: () =>
                      setState(() => _obscurePass = !_obscurePass),
                ),
              ),
              obscureText: _obscurePass,
              textInputAction: TextInputAction.next,
              validator: _validatePassword,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _ownerPass2,
              decoration: InputDecoration(
                labelText: 'Confirm password *',
                hintText: 're-enter it',
                suffixIcon: IconButton(
                  icon: Icon(_obscurePass
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded),
                  tooltip: _obscurePass ? 'Show password' : 'Hide password',
                  onPressed: () =>
                      setState(() => _obscurePass = !_obscurePass),
                ),
              ),
              obscureText: _obscurePass,
              textInputAction: TextInputAction.next,
              validator: _validateConfirm,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _ownerName,
              decoration: const InputDecoration(labelText: 'Owner full name'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 20),
            Text('Business details (printed on bills)',
                style: text.titleSmall),
            const SizedBox(height: 8),
            TextFormField(
              controller: _gstin,
              decoration: const InputDecoration(labelText: 'GSTIN'),
              textInputAction: TextInputAction.next,
              validator: _validateGstin,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pan,
              decoration: const InputDecoration(labelText: 'PAN'),
              textInputAction: TextInputAction.next,
              validator: _validatePan,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _license,
              decoration: const InputDecoration(labelText: 'Shop licence no.'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _address,
              decoration: const InputDecoration(labelText: 'Address'),
              maxLines: 2,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phone,
              decoration: const InputDecoration(labelText: 'Phone'),
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              validator: _validatePhone,
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create cafe'),
            ),
          ],
        ),
      ),
    );
  }

  /// Shown after the cafe exists: a confirmation plus the owner's login details
  /// with Share / Copy so the admin can hand them over in one tap.
  Widget _successView(BuildContext context, Map<String, String> created) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Cafe created')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        children: [
          Icon(Icons.check_circle_rounded, size: 64, color: scheme.primary),
          const SizedBox(height: 12),
          Text(
            '“${created['cafeName']}” is ready',
            textAlign: TextAlign.center,
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'Send these login details to the owner so they can sign in '
            'on their phone.',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          CredentialsCard(
            cafeName: created['cafeName'] ?? '',
            cafeCode: created['cafeCode'] ?? '',
            username: created['username'] ?? '',
            password: created['password'],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

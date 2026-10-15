import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';

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
  final _gstin = TextEditingController();
  final _pan = TextEditingController();
  final _license = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();

  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _slug, _name, _ownerName, _ownerUser, _ownerPass,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cafe “${_name.text.trim()}” created')),
      );
      Navigator.of(context).pop(true);
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
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Add cafe')),
      body: Form(
        key: _formKey,
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
              validator: (v) => _required(v, 2, 'Cafe code'),
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
              validator: (v) => _required(v, 3, 'Owner username'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _ownerPass,
              decoration: const InputDecoration(
                labelText: 'Owner password *',
                hintText: 'min 6 characters',
              ),
              obscureText: true,
              textInputAction: TextInputAction.next,
              validator: (v) => _required(v, 6, 'Owner password'),
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
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pan,
              decoration: const InputDecoration(labelText: 'PAN'),
              textInputAction: TextInputAction.next,
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
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_state.dart';
import '../../widgets/ui_kit.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _tenant = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  bool _showDemo = false;
  String? _error;

  static const _roles = ['Owner', 'Staff', 'Kitchen', 'CA'];

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _tenant.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The cafe code is optional: blank signs into the main cafe.
      await context.read<AuthState>().login(
            _user.text.trim(),
            _pass.text,
            tenant: _tenant.text.trim(),
          );
      // RootGate swaps to the owner/staff shell automatically.
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fillDemo(String user, String pass) {
    setState(() {
      _user.text = user;
      _pass.text = pass;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFFF1E8DE), // warm latte wash
              scheme.surface,
              scheme.surface,
            ],
            stops: const [0.0, 0.32, 1.0],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _hero(context),
                    const SizedBox(height: 14),
                    _signInCard(context),
                    const SizedBox(height: 12),
                    _demoHint(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Gradient hero: brand, tagline and role chips over a latte-art watermark.
  Widget _hero(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return HeroBanner(
      gradient: CafeGradients.coffee,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      illustration: Align(
        alignment: const Alignment(1.3, 0.55),
        child: SizedBox(
          width: 196,
          height: 196,
          child: CustomPaint(
            painter: LatteArtPainter(
              cup: Colors.white.withValues(alpha: 0.14),
              crema: Colors.white.withValues(alpha: 0.11),
              art: Colors.white.withValues(alpha: 0.17),
              bean: Colors.white.withValues(alpha: 0.12),
            ),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.16),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.35)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.14),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: const Icon(Icons.local_cafe_rounded,
                    size: 26, color: Colors.white),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Café POS',
                      style: text.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Billing · KOT · QR orders · GST',
                      style: text.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.88),
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final role in _roles) _roleChip(role),
            ],
          ),
        ],
      ),
    );
  }

  Widget _roleChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _signInCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _user,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.username],
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _pass,
              obscureText: _obscure,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 14),
            // Optional multi-cafe code: blank = the main cafe.
            TextField(
              controller: _tenant,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              onSubmitted: (_) => _login(),
              decoration: const InputDecoration(
                labelText: 'Cafe code',
                helperText:
                    'Ask your owner — e.g. bean_cafe; leave blank for main',
                helperMaxLines: 2,
                prefixIcon: Icon(Icons.storefront_outlined),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: scheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _login,
              icon: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.arrow_forward),
              label: Text(_busy ? 'Signing in…' : 'Sign in'),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RegisterScreen()),
              ),
              child: const Text('New staff? Request an account'),
            ),
          ],
        ),
      ),
    );
  }

  /// Subtle collapsible demo-hint: tap a row to fill the sign-in form.
  Widget _demoHint(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: CafePalette.latte),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => setState(() => _showDemo = !_showDemo),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                children: [
                  const IconChip(
                    icon: Icons.key_rounded,
                    gradient: CafeGradients.sunrise,
                    size: 34,
                    iconSize: 16,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Demo credentials',
                          style: text.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          _showDemo
                              ? 'Tap a row to fill the form'
                              : 'Try the app in a few taps',
                          style: text.bodySmall?.copyWith(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _showDemo
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !_showDemo
                ? const SizedBox(height: 0, width: double.infinity)
                : Container(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                    ),
                    child: Column(
                      children: [
                        _demoRow('owner', 'cafe123', 'Owner'),
                        _demoRow('priya', 'staff123', 'Staff'),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _demoRow(String user, String pass, String role) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _fillDemo(user, pass),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        child: Row(
          children: [
            Expanded(
              child: Text(
                user,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              pass,
              style: text.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: CafePalette.coffee,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              role,
              style: text.bodySmall?.copyWith(
                fontSize: 11,
                color: const Color(0xFF8A6A52),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_forward_rounded,
                size: 14, color: CafePalette.caramel),
          ],
        ),
      ),
    );
  }
}

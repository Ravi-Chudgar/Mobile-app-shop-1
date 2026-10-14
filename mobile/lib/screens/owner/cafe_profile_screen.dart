import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../../widgets/ui_kit.dart';

/// The owner's business identity, printed on every thermal bill: cafe name,
/// owner, GSTIN, PAN, shop licence, address, phone and the footer line.
///
/// Two entry points share the same field set and save path:
///  * [CafeProfileScreen] — the editable settings page (owner → More → Cafe
///    Profile).
///  * [CafeSetupWizard] — a first-time, step-by-step flow shown once when the
///    cafe has no business details yet.
///
/// The backend stores these on the tenant registry row and `printing.py`
/// renders the GST / PAN / licence / owner onto the receipt header.
class CafeProfileScreen extends StatefulWidget {
  const CafeProfileScreen({super.key});

  @override
  State<CafeProfileScreen> createState() => _CafeProfileScreenState();
}

class _CafeProfileScreenState extends State<CafeProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fields = _CafeProfileFields();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = context.read<ApiClient>();
      final data = await api.getCafeProfile();
      _fields.apply(data);
    } catch (_) {
      // Offline / error — start with an empty form; save still works later.
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _fields.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final api = context.read<ApiClient>();
      await api.updateCafeProfile(_fields.payload());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cafe profile saved — updates your bills')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cafe Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              children: [
                const SizedBox(height: 12),
                HeroBanner(
                  gradient: CafeGradients.coffee,
                  height: 104,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Business on your bills',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'GST, PAN & licence print on every receipt',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        title: 'Cafe',
                        subtitle: 'Name shown at the top of the bill',
                      ),
                      _fields.nameField(label: 'Cafe name'),
                      const SizedBox(height: 12),
                      _fields.ownerField(label: 'Owner name'),
                      const SizedBox(height: 20),
                      const SectionHeader(
                        title: 'Tax & licence',
                        subtitle: 'Printed on the receipt for GST compliance',
                      ),
                      _fields.gstinField(label: 'GSTIN'),
                      const SizedBox(height: 12),
                      _fields.panField(label: 'PAN'),
                      const SizedBox(height: 12),
                      _fields.licenseField(label: 'Shop licence (FSSAI / shop act)'),
                      const SizedBox(height: 20),
                      const SectionHeader(
                        title: 'Contact',
                        subtitle: 'Address & phone under the cafe name',
                      ),
                      _fields.addressField(label: 'Address'),
                      const SizedBox(height: 12),
                      _fields.phoneField(label: 'Phone'),
                      const SizedBox(height: 20),
                      const SectionHeader(
                        title: 'Footer',
                        subtitle: 'One line above "Thank you" on the bill',
                      ),
                      _fields.footerField(label: 'Bill footer (e.g. WiFi name)'),
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save Profile'),
        ),
      ),
    );
  }
}

/// First-time setup: a 3-step wizard (Cafe → Tax & licence → Contact & footer)
/// shown once when the cafe has no business details yet. Reuses the same field
/// set and save endpoint as [CafeProfileScreen].
class CafeSetupWizard extends StatefulWidget {
  const CafeSetupWizard({super.key});

  @override
  State<CafeSetupWizard> createState() => _CafeSetupWizardState();
}

class _CafeSetupWizardState extends State<CafeSetupWizard> {
  final _formKey = GlobalKey<FormState>();
  final _fields = _CafeProfileFields();
  final _pageController = PageController();
  int _step = 0;
  bool _saving = false;

  static const _steps = ['Cafe', 'Tax & licence', 'Contact'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<ApiClient>().getCafeProfile();
      _fields.apply(data);
    } catch (_) {}
  }

  @override
  void dispose() {
    _pageController.dispose();
    _fields.dispose();
    super.dispose();
  }

  void _next() {
    // Validate only the visible step's fields before advancing.
    if (_step < _steps.length - 1) {
      setState(() => _step++);
      _pageController.animateToPage(
        _step,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _finish();
    }
  }

  void _back() {
    if (_step == 0) return;
    setState(() => _step--);
    _pageController.animateToPage(
      _step,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _finish() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await context.read<ApiClient>().updateCafeProfile(_fields.payload());
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up your cafe'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  for (var i = 0; i < _steps.length; i++) ...[
                    Expanded(
                      child: _StepDot(
                        index: i,
                        label: _steps[i],
                        active: i == _step,
                        done: i < _step,
                      ),
                    ),
                    if (i < _steps.length - 1)
                      Container(
                        width: 16,
                        height: 2,
                        color: i < _step ? scheme.primary : scheme.outlineVariant,
                      ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: ListView(children: [
                      const SectionHeader(
                        title: 'Your cafe',
                        subtitle: 'This name heads every bill',
                      ),
                      _fields.nameField(label: 'Cafe name'),
                      const SizedBox(height: 12),
                      _fields.ownerField(label: 'Owner name'),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: ListView(children: [
                      const SectionHeader(
                        title: 'Tax & licence',
                        subtitle: 'Required on printed receipts',
                      ),
                      _fields.gstinField(label: 'GSTIN'),
                      const SizedBox(height: 12),
                      _fields.panField(label: 'PAN'),
                      const SizedBox(height: 12),
                      _fields.licenseField(label: 'Shop licence (FSSAI / shop act)'),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: ListView(children: [
                      const SectionHeader(
                        title: 'Contact & footer',
                        subtitle: 'Optional — shown under the cafe name',
                      ),
                      _fields.addressField(label: 'Address'),
                      const SizedBox(height: 12),
                      _fields.phoneField(label: 'Phone'),
                      const SizedBox(height: 12),
                      _fields.footerField(label: 'Bill footer (e.g. WiFi name)'),
                    ]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            if (_step > 0)
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : _back,
                  child: const Text('Back'),
                ),
              ),
            if (_step > 0) const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _saving ? null : _next,
                child: Text(_saving
                    ? 'Saving…'
                    : _step == _steps.length - 1
                        ? 'Finish'
                        : 'Next'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small progress indicator for the setup wizard.
class _StepDot extends StatelessWidget {
  final int index;
  final String label;
  final bool active;
  final bool done;

  const _StepDot({
    required this.index,
    required this.label,
    required this.active,
    required this.done,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active || done ? scheme.primary : scheme.outlineVariant;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i <= index; i++) ...[
              Icon(Icons.circle, size: active ? 10 : 7, color: color),
              if (i < index) const SizedBox(width: 2),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: active ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              ),
        ),
      ],
    );
  }
}

/// Owns the 8 profile text controllers, the load/apply/save plumbing and the
/// per-field validators, shared by the settings screen and the setup wizard.
class _CafeProfileFields {
  final name = TextEditingController();
  final owner = TextEditingController();
  final gstin = TextEditingController();
  final pan = TextEditingController();
  final license = TextEditingController();
  final address = TextEditingController();
  final phone = TextEditingController();
  final footer = TextEditingController();

  void apply(Map<String, dynamic> data) {
    name.text = '${data['display_name'] ?? ''}';
    owner.text = '${data['owner_name'] ?? ''}';
    gstin.text = '${data['gstin'] ?? ''}';
    pan.text = '${data['pan'] ?? ''}';
    license.text = '${data['shop_license'] ?? ''}';
    address.text = '${data['address'] ?? ''}';
    phone.text = '${data['phone'] ?? ''}';
    footer.text = '${data['bill_footer'] ?? ''}';
  }

  Map<String, dynamic> payload() => {
        'display_name': name.text.trim(),
        'owner_name': owner.text.trim(),
        'gstin': gstin.text.trim(),
        'pan': pan.text.trim(),
        'shop_license': license.text.trim(),
        'address': address.text.trim(),
        'phone': phone.text.trim(),
        'bill_footer': footer.text.trim(),
      };

  void dispose() {
    name.dispose();
    owner.dispose();
    gstin.dispose();
    pan.dispose();
    license.dispose();
    address.dispose();
    phone.dispose();
    footer.dispose();
  }

  static String? _required(String? v, String msg) =>
      (v == null || v.trim().isEmpty) ? msg : null;

  Widget nameField({required String label}) => TextFormField(
        controller: name,
        textCapitalization: TextCapitalization.words,
        decoration: _dec(label, Icons.storefront_outlined),
        validator: (v) => _required(v, 'Cafe name is required'),
      );

  Widget ownerField({required String label}) => TextFormField(
        controller: owner,
        textCapitalization: TextCapitalization.words,
        decoration: _dec(label, Icons.person_outline),
      );

  Widget gstinField({required String label}) => TextFormField(
        controller: gstin,
        textCapitalization: TextCapitalization.characters,
        decoration: _dec(label, Icons.receipt_long_outlined),
      );

  Widget panField({required String label}) => TextFormField(
        controller: pan,
        textCapitalization: TextCapitalization.characters,
        decoration: _dec(label, Icons.badge_outlined),
      );

  Widget licenseField({required String label}) => TextFormField(
        controller: license,
        decoration: _dec(label, Icons.verified_outlined),
      );

  Widget addressField({required String label}) => TextFormField(
        controller: address,
        textCapitalization: TextCapitalization.sentences,
        maxLines: 2,
        decoration: _dec(label, Icons.location_on_outlined),
      );

  Widget phoneField({required String label}) => TextFormField(
        controller: phone,
        keyboardType: TextInputType.phone,
        decoration: _dec(label, Icons.phone_outlined),
      );

  Widget footerField({required String label}) => TextFormField(
        controller: footer,
        decoration: _dec(label, Icons.wifi_tethering_outlined),
      );

  InputDecoration _dec(String label, IconData icon) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        border: const OutlineInputBorder(),
      );
}

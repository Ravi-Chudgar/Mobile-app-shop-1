import 'package:flutter/material.dart';

import '../ca/exports_panel.dart';

/// Owner entry point for the accounting exports (Tally XML/CSV and
/// GSTR-1/GSTR-3B). The heavy lifting lives in the shared [ExportsPanel],
/// which the read-only cafe_ca shell shows as its Exports tab too.
class ExportsScreen extends StatelessWidget {
  const ExportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Exports')),
      body: const ExportsPanel(),
    );
  }
}

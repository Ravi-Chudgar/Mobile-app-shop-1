import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cafe_app/main.dart';
import 'package:cafe_app/services/api_client.dart';
import 'package:cafe_app/state/tenant_state.dart';
import 'package:cafe_app/widgets/shell_app_bar.dart';

void main() {
  Widget host(String title) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          appBar: ShellAppBar(
            title: title,
            userName: 'Priya',
            onLogout: () {},
          ),
          body: const SizedBox(),
        ),
      );

  testWidgets(
      'ShellAppBar renders badge, large title, identity chip and logout',
      (tester) async {
    await tester.pumpWidget(host('Staff'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Title is pinned to its real size (TextScaler.noScaling) so it can't
    // shrink and read as a blur of "0"s.
    final title = tester.widget<Text>(find.text('Staff'));
    expect(title.textScaler, TextScaler.noScaling);
    expect(title.style?.fontSize, 26);
    // Badge, identity chip (initial + full name), logout.
    expect(find.byIcon(Icons.local_cafe_rounded), findsOneWidget);
    expect(find.text('P'), findsOneWidget); // Priya's initial
    expect(find.text('Priya'), findsOneWidget);
    expect(find.byIcon(Icons.logout_rounded), findsOneWidget);
  });

  testWidgets('ShellAppBar animates the title when the view changes',
      (tester) async {
    await tester.pumpWidget(host('Sales'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host('Staff'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Staff'), findsOneWidget);
    expect(find.text('Sales'), findsNothing);
  });

  testWidgets('subtitle prefixes the cafe display name once branding loads',
      (tester) async {
    final branding = TenantState(ApiClient())
      ..slug = 'bean'
      ..displayName = 'Bean House Cafe'
      ..kind = 'cafe'
      ..billFooter = 'Thank you';

    Widget brandedHost() => ChangeNotifierProvider<TenantState>.value(
          value: branding,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              appBar: ShellAppBar(
                title: 'Staff',
                subtitle: shellDateLabel(),
                userName: 'Priya',
                onLogout: () {},
              ),
              body: const SizedBox(),
            ),
          ),
        );

    await tester.pumpWidget(brandedHost());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Bean House Cafe · ${shellDateLabel()}'), findsOneWidget);
  });

  testWidgets('subtitle stays date-only without branding', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        appBar: ShellAppBar(
          title: 'Staff',
          subtitle: shellDateLabel(),
          userName: 'Priya',
          onLogout: () {},
        ),
        body: const SizedBox(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(shellDateLabel()), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
  });
}

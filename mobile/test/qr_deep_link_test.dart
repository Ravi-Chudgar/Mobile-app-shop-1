import 'package:cafe_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseQrDeepLink (web table-QR routes)', () {
    test('parses a tenant-scoped card: /t/<slug>/table/<n>', () {
      final link =
          parseQrDeepLink(Uri.parse('https://pos.example/t/bean/table/7'));

      expect(link, isNotNull);
      expect(link!.tenant, 'bean');
      expect(link.tableNumber, '7');
    });

    test('honours a hosting path prefix in front of the route', () {
      final link =
          parseQrDeepLink(Uri.parse('https://pos.example/app/t/bean/table/12'));

      expect(link?.tenant, 'bean');
      expect(link?.tableNumber, '12');
    });

    test('parses a legacy card (/table/<n>) with no cafe code', () {
      final link = parseQrDeepLink(Uri.parse('https://pos.example/table/3'));

      expect(link, isNotNull);
      expect(link!.tenant, isNull);
      expect(link.tableNumber, '3');
    });

    test('falls back to the route after "#" for hash hosting', () {
      final link =
          parseQrDeepLink(Uri.parse('https://pos.example/#/t/hostel/table/5'));

      expect(link?.tenant, 'hostel');
      expect(link?.tableNumber, '5');
    });

    test('ignores unrelated, malformed or root paths', () {
      expect(parseQrDeepLink(Uri.parse('https://pos.example/')), isNull);
      expect(parseQrDeepLink(Uri.parse('https://pos.example/#/')), isNull);
      expect(parseQrDeepLink(Uri.parse('https://pos.example/menu')), isNull);
      expect(parseQrDeepLink(Uri.parse('https://pos.example/table/')), isNull);
      expect(
          parseQrDeepLink(Uri.parse('https://pos.example/t/bean/table/x%20y')),
          isNull);
      expect(
          parseQrDeepLink(
              Uri.parse('https://pos.example/t/bean/table/${'9' * 40}')),
          isNull);
    });
  });
}

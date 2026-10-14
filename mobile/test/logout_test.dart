import 'package:flutter_test/flutter_test.dart';

import 'package:cafe_app/services/api_client.dart';
import 'package:cafe_app/state/auth_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'logout always completes and notifies listeners, '
      'even when secure storage fails', () async {
    final auth = AuthState(ApiClient())
      ..role = 'owner'
      ..username = 'owner'
      ..name = 'Owner';

    var notified = false;
    auth.addListener(() => notified = true);

    // In the test environment flutter_secure_storage has no platform
    // implementation, so `_storage.delete` throws MissingPluginException —
    // the same failure mode a device keychain error (or a hung delete)
    // produces. RootGate only swaps back to the login screen when
    // notifyListeners() fires, so a throw before it makes the logout
    // button appear dead.
    await auth.logout();

    expect(notified, isTrue,
        reason: 'notifyListeners() must fire so RootGate returns to login');
    expect(auth.role, isNull);
    expect(auth.username, isNull);
    expect(auth.isLoggedIn, isFalse);
  });
}

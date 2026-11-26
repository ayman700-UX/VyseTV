import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'febbox.dart';
import 'film_sources.dart';
import 'source_settings.dart';

/// Your FebBox account on this device: its "ui" token, in the system keychain (never in plain
/// settings, never synced to your VyseTV account), and what follows from having one: the FebBox
/// source can be asked.
class FebBox {
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));
  static const _key = 'febbox.ui';

  static FilmSource get source => filmSources.firstWhere((s) => s.id == 'febbox');

  /// A token is saved on this device.
  static final signedIn = ValueNotifier<bool>(false);

  /// Whose it is, once FebBox has said so this session. Null before that, and with no token.
  static final user = ValueNotifier<FebBoxUser?>(null);

  /// Reads the saved token as the app starts.
  static Future<void> initialize() async {
    try {
      final v = await _storage.read(key: _key);
      if (v != null && v.isNotEmpty) febboxToken = v;
    } catch (_) {}
    signedIn.value = febboxReady();
  }

  /// Checks [raw] with FebBox. A valid account's token is kept, and the FebBox source is
  /// switched on and moved to the top of your sources. Null when FebBox doesn't take the token
  /// (nothing changes then); throws when FebBox can't be reached.
  static Future<FebBoxUser?> signIn(String raw) async {
    final token = febboxTidy(raw);
    final u = await febboxUser(token);
    if (u == null) return null;
    febboxToken = token;
    try {
      await _storage.write(key: _key, value: token);
    } catch (_) {}
    user.value = u;
    signedIn.value = true;
    final s = source;
    setFilmSourceOn(s, true);
    setFilmSourceOrder([s, for (final x in orderedFilmSources()) if (x != s) x]);
    return u;
  }

  /// Asks FebBox whose the saved token is, for Settings. Null when FebBox no longer takes it;
  /// throws when FebBox can't be reached.
  static Future<FebBoxUser?> check() async {
    final t = febboxToken;
    if (t == null || t.isEmpty) return null;
    final u = await febboxUser(t);
    if (febboxToken == t) user.value = u;
    return u;
  }

  /// Forgets the token. The source stays where you put it, and is skipped.
  static Future<void> signOut() async {
    febboxToken = null;
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
    user.value = null;
    signedIn.value = false;
  }
}

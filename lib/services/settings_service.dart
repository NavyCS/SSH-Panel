import 'package:shared_preferences/shared_preferences.dart';

/// Persistent user settings for the SSH Panel application.
///
/// Uses [shared_preferences] to store the user's preferred elevation mode:
/// - 'per_action': UAC prompt on every admin action (default)
/// - 'once': Single UAC prompt, the app stays elevated for the session
class SettingsService {
  static const String _keyElevationMode = 'elevation_mode';

  static const String modePerAction = 'per_action';
  static const String modeOnce = 'once';

  SettingsService._();

  static Future<String> getElevationMode() async {
    final prefs = await _getPrefs();
    return prefs.getString(_keyElevationMode) ?? modePerAction;
  }

  static Future<void> setElevationMode(String mode) async {
    final prefs = await _getPrefs();
    await prefs.setString(_keyElevationMode, mode);
  }

  static Future<bool> isOnceMode() async {
    return await getElevationMode() == modeOnce;
  }

  static Future<SharedPreferences> _getPrefs() async {
    return await SharedPreferences.getInstance();
  }
}

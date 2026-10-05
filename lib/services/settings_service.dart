import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

/// Persistent user settings for the SSH Panel application.
///
/// Uses [shared_preferences] to store the user's preferred elevation mode:
/// - 'per_action': UAC prompt on every admin action (default)
/// - 'once': Single UAC prompt, the app stays elevated for the session
///
/// Also stores the preferred theme:
/// - 'system': follow the Windows app theme setting (default)
/// - 'light': always light
/// - 'dark': always dark
class SettingsService {
  static const String _keyElevationMode = 'elevation_mode';
  static const String _keyThemeMode = 'theme_mode';

  static const String modePerAction = 'per_action';
  static const String modeOnce = 'once';

  /// Theme preference values. These are the Flutter [ThemeMode] names, so
  /// mapping a stored string to a theme is a lookup by name rather than a
  /// hand-maintained switch that could drift.
  static const String themeSystem = 'system';
  static const String themeLight = 'light';
  static const String themeDark = 'dark';

  /// Every valid [themeMode] value, in the order shown in the picker.
  static const List<String> themeModeOptions = [themeSystem, themeLight, themeDark];

  SettingsService._();

  /// Reactive notifier for UI components listening to elevation mode changes.
  static final ValueNotifier<String> elevationModeNotifier =
      ValueNotifier<String>(modePerAction);

  /// Reactive notifier for UI components listening to theme changes.
  static final ValueNotifier<String> themeModeNotifier =
      ValueNotifier<String>(themeSystem);

  static Future<String> getElevationMode() async {
    final prefs = await _getPrefs();
    final mode = prefs.getString(_keyElevationMode) ?? modePerAction;
    elevationModeNotifier.value = mode;
    return mode;
  }

  static Future<void> setElevationMode(String mode) async {
    final prefs = await _getPrefs();
    await prefs.setString(_keyElevationMode, mode);
    elevationModeNotifier.value = mode;
  }

  /// Reads the stored theme preference, defaulting to [themeSystem].
  ///
  /// A stored value that is no longer in [themeModeOptions] is treated as
  /// [themeSystem] rather than passed through, so a downgrade or a hand-edited
  /// preferences file cannot leave the app on an unresolvable theme.
  static Future<String> getThemeMode() async {
    final prefs = await _getPrefs();
    final stored = prefs.getString(_keyThemeMode) ?? themeSystem;
    final mode = themeModeOptions.contains(stored) ? stored : themeSystem;
    themeModeNotifier.value = mode;
    return mode;
  }

  static Future<void> setThemeMode(String mode) async {
    if (!themeModeOptions.contains(mode)) return;
    final prefs = await _getPrefs();
    await prefs.setString(_keyThemeMode, mode);
    themeModeNotifier.value = mode;
  }

  static bool? _cachedIsElevated;

  /// Checks whether the current process is running with Administrator privileges
  /// via Win32 `shell32.dll`'s `IsUserAnAdmin`.
  static bool isProcessElevated() {
    if (_cachedIsElevated != null) return _cachedIsElevated!;
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final isUserAnAdmin = shell32.lookupFunction<Int32 Function(), int Function()>('IsUserAnAdmin');
      _cachedIsElevated = isUserAnAdmin() != 0;
      return _cachedIsElevated!;
    } catch (_) {
      return false;
    }
  }

  /// Relaunches the application elevated via UAC ('runas').
  /// If accepted by the user (result > 32), exits the current process immediately.
  /// Returns `false` if user canceled the UAC prompt or it failed.
  static bool restartElevated() {
    return using((arena) {
      final result = ShellExecute(
        null,
        arena.pcwstr('runas'),
        arena.pcwstr(Platform.resolvedExecutable),
        null,
        null,
        SW_SHOWNORMAL,
      );
      if (result.address > 32) {
        exit(0);
      }
      return false;
    });
  }

  static Future<SharedPreferences> _getPrefs() async {
    return await SharedPreferences.getInstance();
  }
}

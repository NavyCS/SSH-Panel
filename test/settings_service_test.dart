/// Tests for the persisted theme preference.
///
/// The interesting cases are the ones where a stored value cannot be trusted:
/// a preferences file edited by hand, or written by an older build that knew
/// different values. Neither should be able to leave the app on a theme it
/// cannot resolve.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_panel/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('theme mode values', () {
    test('are exactly the ThemeMode names', () {
      // The app maps a stored string to a ThemeMode by name. If these ever
      // diverge from the enum the lookup silently falls back to system, so
      // pin the relationship here rather than trusting it.
      for (final name in SettingsService.themeModeOptions) {
        expect(
          ThemeMode.values.any((mode) => mode.name == name),
          isTrue,
          reason: '$name is not a ThemeMode name',
        );
      }
    });

    test('cover all three ThemeMode values', () {
      expect(SettingsService.themeModeOptions, hasLength(3));
      expect(
        SettingsService.themeModeOptions.toSet(),
        {'system', 'light', 'dark'},
      );
    });

    test('default to system when nothing is stored', () async {
      expect(await SettingsService.getThemeMode(), SettingsService.themeSystem);
    });
  });

  group('SettingsService.getThemeMode', () {
    test('returns the stored value', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
      expect(await SettingsService.getThemeMode(), SettingsService.themeDark);
    });

    test('falls back to system for an unrecognised stored value', () async {
      // A hand-edited or downgraded preferences file must not crash startup.
      SharedPreferences.setMockInitialValues({'theme_mode': 'solarized'});
      expect(await SettingsService.getThemeMode(), SettingsService.themeSystem);
    });

    test('falls back to system for an empty stored value', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': ''});
      expect(await SettingsService.getThemeMode(), SettingsService.themeSystem);
    });

    test('publishes the resolved value, not the raw stored one', () async {
      // The notifier drives the UI. Publishing the raw value would make the
      // app fall back to system at render time while the picker showed the
      // invalid string.
      SharedPreferences.setMockInitialValues({'theme_mode': 'nonsense'});
      await SettingsService.getThemeMode();
      expect(
        SettingsService.themeModeNotifier.value,
        SettingsService.themeSystem,
      );
    });
  });

  group('SettingsService.setThemeMode', () {
    test('persists and publishes a valid value', () async {
      await SettingsService.setThemeMode(SettingsService.themeDark);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_mode'), SettingsService.themeDark);
      expect(
        SettingsService.themeModeNotifier.value,
        SettingsService.themeDark,
      );
    });

    test('ignores an invalid value without persisting or publishing', () async {
      await SettingsService.setThemeMode(SettingsService.themeLight);
      SettingsService.themeModeNotifier.value = SettingsService.themeLight;

      await SettingsService.setThemeMode('not-a-theme');

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('theme_mode'),
        SettingsService.themeLight,
        reason: 'the previous valid value must survive',
      );
      expect(
        SettingsService.themeModeNotifier.value,
        SettingsService.themeLight,
        reason: 'an invalid value must not reach the UI',
      );
    });

    test('round-trips every option', () async {
      for (final mode in SettingsService.themeModeOptions) {
        await SettingsService.setThemeMode(mode);
        expect(await SettingsService.getThemeMode(), mode);
      }
    });
  });

  group('theme preference is independent of elevation', () {
    test('reading the theme does not disturb the elevation mode', () async {
      await SettingsService.setElevationMode(SettingsService.modeOnce);
      await SettingsService.setThemeMode(SettingsService.themeDark);
      expect(await SettingsService.getElevationMode(), SettingsService.modeOnce);
      expect(await SettingsService.getThemeMode(), SettingsService.themeDark);
    });
  });
}
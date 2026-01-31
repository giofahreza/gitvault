import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Theme mode options for the app
enum AppThemeMode {
  light,
  dark,
  system;

  /// Convert AppThemeMode to Flutter's ThemeMode
  ThemeMode toThemeMode() {
    switch (this) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }

  /// Parse string to AppThemeMode
  static AppThemeMode fromString(String value) {
    switch (value.toLowerCase()) {
      case 'light':
        return AppThemeMode.light;
      case 'dark':
        return AppThemeMode.dark;
      case 'system':
      default:
        return AppThemeMode.system;
    }
  }

  /// Convert to string for storage
  String toStorageString() {
    switch (this) {
      case AppThemeMode.light:
        return 'light';
      case AppThemeMode.dark:
        return 'dark';
      case AppThemeMode.system:
        return 'system';
    }
  }

  /// Get display label for UI
  String getLabel() {
    switch (this) {
      case AppThemeMode.light:
        return 'Light';
      case AppThemeMode.dark:
        return 'Dark';
      case AppThemeMode.system:
        return 'System';
    }
  }
}

/// State provider for theme mode
/// Defaults to system theme to respect user's OS preference
final themeModeProvider = StateProvider<AppThemeMode>((ref) => AppThemeMode.system);

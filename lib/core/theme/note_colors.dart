import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Dual color palettes for Notes feature
/// Provides brightness-aware warm note colors drawn from the GitVault palette.
class NoteColorPalette {
  // Prevent instantiation
  NoteColorPalette._();

  /// Light theme palette - warm paper, oxblood, and ember variants.
  static const Map<int, Color> _lightPalette = {
    0: GitVaultPalette.lightSurface,
    1: GitVaultPalette.lightSignal,
    2: GitVaultPalette.lightTerracotta,
    3: GitVaultPalette.lightFocus,
    4: GitVaultPalette.lightSignalDeep,
    5: GitVaultPalette.lightOxblood,
    6: GitVaultPalette.lightSurfaceWarm,
    7: GitVaultPalette.lightSurfaceSoft,
    8: GitVaultPalette.lightOxbloodDeep,
    9: GitVaultPalette.lightSignal,
    10: GitVaultPalette.lightInkSoft,
  };

  /// Dark theme palette - deep oxblood surfaces with white type.
  static const Map<int, Color> _darkPalette = {
    0: GitVaultPalette.darkSurface,
    1: GitVaultPalette.darkOxblood,
    2: GitVaultPalette.darkOxbloodDeep,
    3: GitVaultPalette.darkSurfaceWarm,
    4: GitVaultPalette.darkSurfaceSoft,
    5: GitVaultPalette.darkOxblood,
    6: GitVaultPalette.darkSurfaceWarm,
    7: GitVaultPalette.darkSurfaceSoft,
    8: GitVaultPalette.darkOxbloodDeep,
    9: GitVaultPalette.darkOxblood,
    10: GitVaultPalette.darkSurfaceSoft,
  };

  /// Get the appropriate color for the given color index and brightness
  static Color getColor(int colorIndex, Brightness brightness) {
    final palette = brightness == Brightness.light ? _lightPalette : _darkPalette;
    return palette[colorIndex] ?? palette[0]!;
  }

  /// Get text color that contrasts with the note background.
  static Color getTextColor(int colorIndex, Brightness brightness) {
    final background = getColor(colorIndex, brightness);
    return background.computeLuminance() > 0.18
        ? GitVaultPalette.lightOxbloodDeep
        : GitVaultPalette.white;
  }

  /// Get border color for note cards
  /// Subtle border that works in both themes
  static Color getBorderColor(int colorIndex, Brightness brightness) {
    return brightness == Brightness.light
        ? GitVaultPalette.lightInk.withOpacity(0.12)
        : GitVaultPalette.white.withOpacity(0.12);
  }

  /// Get background color for tags/chips on notes
  /// Slightly darker/lighter than note background for contrast
  static Color getTagBackgroundColor(int colorIndex, Brightness brightness) {
    return brightness == Brightness.light
        ? GitVaultPalette.lightInk.withOpacity(0.08)
        : GitVaultPalette.white.withOpacity(0.15);
  }

  /// Get icon color (pin, menu) on note cards
  /// Ensures icons are visible on all note backgrounds
  static Color getIconColor(Brightness brightness) {
    return brightness == Brightness.light
        ? GitVaultPalette.lightInk.withOpacity(0.6)
        : GitVaultPalette.white.withOpacity(0.7);
  }

  /// Get hint text color for note editor
  /// 50% opacity of main text color
  static Color getHintColor(int colorIndex, Brightness brightness) {
    return getTextColor(colorIndex, brightness).withOpacity(0.5);
  }
}

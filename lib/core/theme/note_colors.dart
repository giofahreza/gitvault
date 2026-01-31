import 'package:flutter/material.dart';

/// Dual color palettes for Notes feature
/// Provides brightness-aware colors for all 11 Google Keep-style note colors
/// Critical for ensuring readability in both light and dark themes
class NoteColorPalette {
  // Prevent instantiation
  NoteColorPalette._();

  /// Light theme palette - Google Keep style pastel colors
  static const Map<int, Color> _lightPalette = {
    0: Color(0xFFFFFFFF), // White
    1: Color(0xFFF28B82), // Red
    2: Color(0xFFFBBC04), // Orange
    3: Color(0xFFFFF475), // Yellow
    4: Color(0xFFCCFF90), // Green
    5: Color(0xFFA7FFEB), // Teal
    6: Color(0xFFCBF0F8), // Cyan
    7: Color(0xFFAECBFA), // Blue
    8: Color(0xFFD7AEFB), // Purple
    9: Color(0xFFFDCFE8), // Pink
    10: Color(0xFFE6C9A8), // Brown
  };

  /// Dark theme palette - Deep saturated variants for readability
  static const Map<int, Color> _darkPalette = {
    0: Color(0xFF202124), // Dark grey (instead of white)
    1: Color(0xFF5C2B29), // Deep red
    2: Color(0xFF614A19), // Deep orange
    3: Color(0xFF635D19), // Deep yellow
    4: Color(0xFF345920), // Deep green
    5: Color(0xFF16504B), // Deep teal
    6: Color(0xFF2D555E), // Deep cyan
    7: Color(0xFF1E3A5F), // Deep blue
    8: Color(0xFF42275E), // Deep purple
    9: Color(0xFF5B2245), // Deep pink
    10: Color(0xFF442F1E), // Deep brown
  };

  /// Get the appropriate color for the given color index and brightness
  static Color getColor(int colorIndex, Brightness brightness) {
    final palette = brightness == Brightness.light ? _lightPalette : _darkPalette;
    return palette[colorIndex] ?? palette[0]!;
  }

  /// Get text color that contrasts with the note background
  /// Light theme: dark text, Dark theme: light text
  static Color getTextColor(int colorIndex, Brightness brightness) {
    return brightness == Brightness.light
        ? Colors.black87
        : Colors.white.withOpacity(0.9);
  }

  /// Get border color for note cards
  /// Subtle border that works in both themes
  static Color getBorderColor(int colorIndex, Brightness brightness) {
    return brightness == Brightness.light
        ? Colors.black.withOpacity(0.12)
        : Colors.white.withOpacity(0.12);
  }

  /// Get background color for tags/chips on notes
  /// Slightly darker/lighter than note background for contrast
  static Color getTagBackgroundColor(int colorIndex, Brightness brightness) {
    return brightness == Brightness.light
        ? Colors.black.withOpacity(0.08)
        : Colors.white.withOpacity(0.15);
  }

  /// Get icon color (pin, menu) on note cards
  /// Ensures icons are visible on all note backgrounds
  static Color getIconColor(Brightness brightness) {
    return brightness == Brightness.light
        ? Colors.black.withOpacity(0.6)
        : Colors.white.withOpacity(0.7);
  }

  /// Get hint text color for note editor
  /// 50% opacity of main text color
  static Color getHintColor(int colorIndex, Brightness brightness) {
    return getTextColor(colorIndex, brightness).withOpacity(0.5);
  }
}

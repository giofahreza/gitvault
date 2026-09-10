import 'package:flutter/material.dart';

/// The shared GitVault palette.
///
/// These values intentionally mirror the public landing site so the product
/// feels like one system on web, desktop, and mobile. Keep this palette in
/// sync with the tokens in `docs/styles.css` and `docs/docs.css`.
class GitVaultPalette {
  GitVaultPalette._();

  static const Color white = Color(0xFFFFFFFF);

  // Landing light theme.
  static const Color lightPage = Color(0xFFF7EFEA);
  static const Color lightSurface = Color(0xFFFFFAF7);
  static const Color lightSurfaceSoft = Color(0xFFF2E3DC);
  static const Color lightSurfaceWarm = Color(0xFFECD8CF);
  static const Color lightInk = Color(0xFF2C1718);
  static const Color lightInkSoft = Color(0xFF5F4543);
  static const Color lightMuted = Color(0xFF7E6663);
  static const Color lightOxblood = Color(0xFF6D221F);
  static const Color lightOxbloodDeep = Color(0xFF321112);
  static const Color lightSignal = Color(0xFFED735A);
  static const Color lightSignalDeep = Color(0xFFBD4032);
  static const Color lightTerracotta = Color(0xFFD15845);
  static const Color lightFocus = Color(0xFFB94736);

  // Landing dark theme.
  static const Color darkPage = Color(0xFF180D0E);
  static const Color darkSurface = Color(0xFF281718);
  static const Color darkSurfaceSoft = Color(0xFF35201F);
  static const Color darkSurfaceWarm = Color(0xFF442825);
  static const Color darkOxblood = Color(0xFF7C2923);
  static const Color darkOxbloodDeep = Color(0xFF341112);
  static const Color darkSignal = Color(0xFFFF866D);
  static const Color darkSignalDeep = Color(0xFFDF5747);
  static const Color darkTerracotta = Color(0xFFFF9A85);
  static const Color darkFocus = Color(0xFFFFAD98);
}

/// Central Material 3 configuration for GitVault.
///
/// Both schemes use the exact landing-page palette rather than generated seed
/// colors. That keeps every `ColorScheme` consumer in the Flutter app aligned
/// with the public web experience.
class AppTheme {
  AppTheme._();

  static const ColorScheme _lightColorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: GitVaultPalette.lightOxblood,
    onPrimary: GitVaultPalette.white,
    primaryContainer: GitVaultPalette.lightSurfaceWarm,
    onPrimaryContainer: GitVaultPalette.lightInk,
    primaryFixed: GitVaultPalette.lightSurfaceWarm,
    primaryFixedDim: GitVaultPalette.lightTerracotta,
    onPrimaryFixed: GitVaultPalette.lightInk,
    onPrimaryFixedVariant: GitVaultPalette.lightOxbloodDeep,
    secondary: GitVaultPalette.lightSignalDeep,
    onSecondary: GitVaultPalette.white,
    secondaryContainer: GitVaultPalette.lightSurfaceSoft,
    onSecondaryContainer: GitVaultPalette.lightInk,
    secondaryFixed: GitVaultPalette.lightSurfaceSoft,
    secondaryFixedDim: GitVaultPalette.lightSignal,
    onSecondaryFixed: GitVaultPalette.lightInk,
    onSecondaryFixedVariant: GitVaultPalette.lightOxbloodDeep,
    tertiary: GitVaultPalette.lightSignal,
    onTertiary: GitVaultPalette.lightInk,
    tertiaryContainer: GitVaultPalette.lightSurfaceWarm,
    onTertiaryContainer: GitVaultPalette.lightInk,
    tertiaryFixed: GitVaultPalette.lightSurfaceWarm,
    tertiaryFixedDim: GitVaultPalette.lightSignal,
    onTertiaryFixed: GitVaultPalette.lightInk,
    onTertiaryFixedVariant: GitVaultPalette.lightOxbloodDeep,
    error: GitVaultPalette.lightSignalDeep,
    onError: GitVaultPalette.white,
    errorContainer: GitVaultPalette.lightSurfaceWarm,
    onErrorContainer: GitVaultPalette.lightInk,
    surface: GitVaultPalette.lightSurface,
    onSurface: GitVaultPalette.lightInk,
    surfaceDim: GitVaultPalette.lightSurfaceWarm,
    surfaceBright: GitVaultPalette.lightSurface,
    surfaceContainerLowest: GitVaultPalette.lightSurface,
    surfaceContainerLow: GitVaultPalette.lightPage,
    surfaceContainer: GitVaultPalette.lightSurfaceSoft,
    surfaceContainerHigh: GitVaultPalette.lightSurfaceWarm,
    surfaceContainerHighest: GitVaultPalette.lightSurfaceWarm,
    onSurfaceVariant: GitVaultPalette.lightInkSoft,
    outline: GitVaultPalette.lightMuted,
    outlineVariant: GitVaultPalette.lightSurfaceWarm,
    shadow: GitVaultPalette.lightOxbloodDeep,
    scrim: GitVaultPalette.lightOxbloodDeep,
    inverseSurface: GitVaultPalette.lightOxbloodDeep,
    onInverseSurface: GitVaultPalette.white,
    inversePrimary: GitVaultPalette.lightSignal,
    surfaceTint: GitVaultPalette.lightOxblood,
  );

  static const ColorScheme _darkColorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: GitVaultPalette.darkOxblood,
    onPrimary: GitVaultPalette.white,
    primaryContainer: GitVaultPalette.darkSurfaceWarm,
    onPrimaryContainer: GitVaultPalette.white,
    primaryFixed: GitVaultPalette.lightSurfaceWarm,
    primaryFixedDim: GitVaultPalette.darkSignal,
    onPrimaryFixed: GitVaultPalette.lightInk,
    onPrimaryFixedVariant: GitVaultPalette.darkOxbloodDeep,
    secondary: GitVaultPalette.darkSignalDeep,
    onSecondary: GitVaultPalette.lightOxbloodDeep,
    secondaryContainer: GitVaultPalette.darkSurfaceSoft,
    onSecondaryContainer: GitVaultPalette.white,
    secondaryFixed: GitVaultPalette.lightSurfaceSoft,
    secondaryFixedDim: GitVaultPalette.darkSignal,
    onSecondaryFixed: GitVaultPalette.lightInk,
    onSecondaryFixedVariant: GitVaultPalette.darkOxbloodDeep,
    tertiary: GitVaultPalette.darkSignal,
    onTertiary: GitVaultPalette.lightOxbloodDeep,
    tertiaryContainer: GitVaultPalette.darkSurfaceWarm,
    onTertiaryContainer: GitVaultPalette.white,
    tertiaryFixed: GitVaultPalette.lightSurfaceWarm,
    tertiaryFixedDim: GitVaultPalette.darkTerracotta,
    onTertiaryFixed: GitVaultPalette.lightInk,
    onTertiaryFixedVariant: GitVaultPalette.darkOxbloodDeep,
    error: GitVaultPalette.darkSignal,
    onError: GitVaultPalette.lightOxbloodDeep,
    errorContainer: GitVaultPalette.darkSurfaceWarm,
    onErrorContainer: GitVaultPalette.white,
    surface: GitVaultPalette.darkSurface,
    onSurface: GitVaultPalette.white,
    surfaceDim: GitVaultPalette.darkPage,
    surfaceBright: GitVaultPalette.darkSurfaceWarm,
    surfaceContainerLowest: GitVaultPalette.darkPage,
    surfaceContainerLow: GitVaultPalette.darkSurface,
    surfaceContainer: GitVaultPalette.darkSurfaceSoft,
    surfaceContainerHigh: GitVaultPalette.darkSurfaceWarm,
    surfaceContainerHighest: GitVaultPalette.darkSurfaceWarm,
    onSurfaceVariant: GitVaultPalette.white,
    outline: GitVaultPalette.darkFocus,
    outlineVariant: GitVaultPalette.darkSurfaceWarm,
    shadow: GitVaultPalette.darkPage,
    scrim: GitVaultPalette.darkPage,
    inverseSurface: GitVaultPalette.lightSurface,
    onInverseSurface: GitVaultPalette.lightInk,
    inversePrimary: GitVaultPalette.lightOxblood,
    surfaceTint: GitVaultPalette.darkOxblood,
  );

  /// Light theme configuration.
  static ThemeData lightTheme() {
    return _buildTheme(
      _lightColorScheme,
      pageColor: GitVaultPalette.lightPage,
      cardElevation: 1,
    );
  }

  /// Dark theme configuration.
  static ThemeData darkTheme() {
    return _buildTheme(
      _darkColorScheme,
      pageColor: GitVaultPalette.darkPage,
      cardElevation: 2,
    );
  }

  static ThemeData _buildTheme(
    ColorScheme colorScheme, {
    required Color pageColor,
    required double cardElevation,
  }) {
    final outlineBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: colorScheme.outlineVariant),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: pageColor,
      canvasColor: colorScheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: cardElevation,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surface,
        hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
        border: outlineBorder,
        enabledBorder: outlineBorder,
        focusedBorder: outlineBorder.copyWith(
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        errorBorder: outlineBorder.copyWith(
          borderSide: BorderSide(color: colorScheme.error),
        ),
        focusedErrorBorder: outlineBorder.copyWith(
          borderSide: BorderSide(color: colorScheme.error, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: colorScheme.primary),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainer,
        selectedColor: colorScheme.primaryContainer,
        secondarySelectedColor: colorScheme.secondaryContainer,
        disabledColor: colorScheme.surfaceContainerHigh,
        labelStyle: TextStyle(color: colorScheme.onSurface),
        secondaryLabelStyle: TextStyle(color: colorScheme.onSecondaryContainer),
        side: BorderSide(color: colorScheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surface,
        indicatorColor: colorScheme.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(color: colorScheme.onSurface),
        ),
        iconTheme: WidgetStatePropertyAll(
          IconThemeData(color: colorScheme.onSurfaceVariant),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colorScheme.surface,
        indicatorColor: colorScheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: colorScheme.onPrimaryContainer),
        selectedLabelTextStyle: TextStyle(
          color: colorScheme.onPrimaryContainer,
        ),
        unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
        unselectedLabelTextStyle: TextStyle(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        actionTextColor: colorScheme.inversePrimary,
      ),
    );
  }
}

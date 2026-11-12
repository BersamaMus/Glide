import 'package:flutter/material.dart';

/// The palette, shared with Blimp and Vessel: black surfaces with an accent
/// of the app's own (teal here; Blimp is yellow and Vessel purple).
abstract final class AppColors {
  static const background = Color(0xFF000000);
  static const surface = Color(0xFF0F0F0F);
  static const surfaceHigh = Color(0xFF1C1C1C);
  static const surfaceHover = Color(0xFF2E2E2E);
  static const sheet = Color(0xFF141414);
  static const accent = Color(0xFF5EEAD4);

  /// Text and icons on the accent colour.
  static const onAccent = Color(0xFF042F2A);

  /// Accent-tinted fill for selected tabs and tiles.
  static const accentSoft = Color(0x2E5EEAD4);
  static const danger = Color(0xFFF05252);
  static const textSecondary = Color(0xFFADADAD);
  static const textTertiary = Color(0xFF858585);
  static const hover = Color(0x14FFFFFF);
  static const divider = Color(0x14FFFFFF);
  static const outline = Color(0x26FFFFFF);
}

abstract final class AppRadius {
  static const art = 12.0;
  static const card = 16.0;
  static const large = 24.0;
}

ThemeData buildTheme() {
  final scheme = ColorScheme.dark(
    primary: AppColors.accent,
    onPrimary: AppColors.onAccent,
    secondary: AppColors.accent,
    onSecondary: AppColors.onAccent,
    surface: AppColors.background,
    onSurface: Colors.white,
    onSurfaceVariant: AppColors.textSecondary,
    surfaceContainerLowest: AppColors.background,
    surfaceContainerLow: AppColors.surface,
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: AppColors.surfaceHigh,
    outline: AppColors.outline,
    outlineVariant: AppColors.divider,
    error: AppColors.danger,
  );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final text = base.textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white);
  const stadium = StadiumBorder();
  RoundedRectangleBorder rounded(double r) => RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    textTheme: text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 20, letterSpacing: -0.2),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      bodyMedium: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
      bodySmall: text.bodySmall?.copyWith(color: AppColors.textSecondary),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: Colors.white,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: AppColors.surfaceHigh,
      indicatorColor: AppColors.accentSoft,
      indicatorShape: stadium,
      labelType: NavigationRailLabelType.all,
      selectedIconTheme: const IconThemeData(size: 24, color: AppColors.accent),
      unselectedIconTheme: const IconThemeData(size: 24, color: AppColors.textSecondary),
      selectedLabelTextStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.accent),
      unselectedLabelTextStyle: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppColors.textSecondary,
      ),
    ),
    navigationDrawerTheme: const NavigationDrawerThemeData(
      backgroundColor: AppColors.sheet,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AppColors.accentSoft,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.onAccent,
        shape: stadium,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accent,
        shape: stadium,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.sheet,
      surfaceTintColor: Colors.transparent,
      shape: rounded(AppRadius.large),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: rounded(AppRadius.card),
      textStyle: const TextStyle(fontSize: 15, color: Colors.white),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: const TextStyle(color: Colors.white),
      actionTextColor: AppColors.accent,
      shape: rounded(AppRadius.card),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.divider, space: 1),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.accent,
      selectionHandleColor: AppColors.accent,
    ),
  );
}

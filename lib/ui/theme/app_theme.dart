// SPDX-License-Identifier: GPL-3.0-or-later

/// "Field recorder" theme: warm graphite neutrals, one recording-light accent,
/// Roboto Flex, spring motion. Colors are only ever consumed through
/// [ColorScheme] roles; the seed below is the single brand hex.
library;

import 'package:material_3_expressive/material_3_expressive.dart' show M3ESpring, M3EThemeData;
import 'package:material_ui/material_ui.dart';

/// Recording-light vermilion. Used when the platform provides no accent.
const Color brandSeed = Color(0xFFE5482D);

const String fontFamily = 'Roboto Flex';

/// Motion tokens. Shape changes use the expressive spatial spring (slight
/// overshoot); color and opacity use the effects spring (no overshoot).
abstract final class Motion {
  static const spatial = M3ESpring(stiffness: 380, damping: 0.7);
  static const spatialSlow = M3ESpring(stiffness: 300, damping: 0.9);
  static const effects = M3ESpring(stiffness: 1600, damping: 1);

  static const short = Duration(milliseconds: 150);
  static const medium = Duration(milliseconds: 250);
  static const long = Duration(milliseconds: 400);

  /// Zero when the platform asks for reduced motion.
  static Duration of(BuildContext context, [Duration d = medium]) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : d;
}

/// Extra text styles that do not exist in the Material type scale.
@immutable
class RambleTextStyles extends ThemeExtension<RambleTextStyles> {
  const RambleTextStyles({required this.result, required this.timer, required this.timerLarge});

  /// Dictated text on the result card.
  final TextStyle result;

  /// Elapsed time, tabular figures.
  final TextStyle timer;
  final TextStyle timerLarge;

  static RambleTextStyles of(BuildContext context) =>
      Theme.of(context).extension<RambleTextStyles>() ?? _fallback;

  static const _fallback = RambleTextStyles(result: TextStyle(), timer: TextStyle(), timerLarge: TextStyle());

  @override
  RambleTextStyles copyWith({TextStyle? result, TextStyle? timer, TextStyle? timerLarge}) =>
      RambleTextStyles(
        result: result ?? this.result,
        timer: timer ?? this.timer,
        timerLarge: timerLarge ?? this.timerLarge,
      );

  @override
  RambleTextStyles lerp(RambleTextStyles? other, double t) => other == null
      ? this
      : RambleTextStyles(
          result: TextStyle.lerp(result, other.result, t)!,
          timer: TextStyle.lerp(timer, other.timer, t)!,
          timerLarge: TextStyle.lerp(timerLarge, other.timerLarge, t)!,
        );
}

/// Shape tokens (M3 corner scale).
abstract final class Shapes {
  static const double small = 8;
  static const double medium = 12;
  static const double large = 16;
  static const double extraLarge = 28;
  static BorderRadius get cardRadius => BorderRadius.circular(large);
  static BorderRadius get sheetRadius => BorderRadius.circular(extraLarge);
}

List<FontVariation> _axes(double weight, double opsz, {double grade = 0}) => [
      FontVariation('wght', weight),
      FontVariation('opsz', opsz.clamp(8, 144)),
      FontVariation('GRAD', grade),
    ];

TextStyle _s(double size, double lh, double weight, {double ls = 0, double grade = 0}) => TextStyle(
      fontFamily: fontFamily,
      fontSize: size,
      height: lh / size,
      letterSpacing: ls,
      fontWeight: FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)],
      fontVariations: _axes(weight, size, grade: grade),
    );

/// Baseline scale on the left, emphasized (heavier, graded) on display and
/// headline roles for the dictated result.
TextTheme _textTheme(Color color) {
  final base = TextTheme(
    displayLarge: _s(57, 64, 600, ls: -0.25),
    displayMedium: _s(45, 52, 600),
    displaySmall: _s(36, 44, 600),
    headlineLarge: _s(32, 40, 600),
    headlineMedium: _s(28, 36, 600),
    headlineSmall: _s(24, 32, 600),
    titleLarge: _s(22, 28, 500),
    titleMedium: _s(16, 24, 600, ls: 0.15),
    titleSmall: _s(14, 20, 600, ls: 0.1),
    bodyLarge: _s(16, 24, 400, ls: 0.5),
    bodyMedium: _s(14, 20, 400, ls: 0.25),
    bodySmall: _s(12, 16, 400, ls: 0.4),
    labelLarge: _s(14, 20, 600, ls: 0.1),
    labelMedium: _s(12, 16, 600, ls: 0.5),
    labelSmall: _s(11, 16, 600, ls: 0.5),
  );
  return base.apply(displayColor: color, bodyColor: color);
}

ColorScheme _scheme(Brightness brightness, Color? accent) {
  final scheme = ColorScheme.fromSeed(
    seedColor: accent ?? brandSeed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
  );
  if (accent != null) return scheme;
  // Brand fallback: pin the recording light as primary and warm the neutrals.
  final dark = brightness == Brightness.dark;
  return scheme.copyWith(
    primary: dark ? const Color(0xFFFFB4A4) : brandSeed,
    onPrimary: dark ? const Color(0xFF5F1500) : const Color(0xFFFFFFFF),
    primaryContainer: dark ? const Color(0xFF8A2410) : const Color(0xFFFFDAD2),
    onPrimaryContainer: dark ? const Color(0xFFFFDAD2) : const Color(0xFF3A0900),
    surface: dark ? const Color(0xFF1A1816) : const Color(0xFFFAF7F4),
    onSurface: dark ? const Color(0xFFEAE4DF) : const Color(0xFF1D1B19),
    onSurfaceVariant: dark ? const Color(0xFFCFC6BF) : const Color(0xFF4F4842),
    surfaceDim: dark ? const Color(0xFF14120F) : const Color(0xFFDDD8D3),
    surfaceBright: dark ? const Color(0xFF3A3633) : const Color(0xFFFAF7F4),
    surfaceContainerLowest: dark ? const Color(0xFF0F0D0B) : const Color(0xFFFFFFFF),
    surfaceContainerLow: dark ? const Color(0xFF211F1C) : const Color(0xFFF5F1ED),
    surfaceContainer: dark ? const Color(0xFF262421) : const Color(0xFFF0EBE7),
    surfaceContainerHigh: dark ? const Color(0xFF312E2B) : const Color(0xFFEAE5E1),
    surfaceContainerHighest: dark ? const Color(0xFF3C3936) : const Color(0xFFE4DFDB),
    outline: dark ? const Color(0xFF988F88) : const Color(0xFF81776F),
    outlineVariant: dark ? const Color(0xFF4F4842) : const Color(0xFFD3C8C0),
  );
}

ThemeData buildTheme({required Brightness brightness, Color? accent}) {
  final scheme = _scheme(brightness, accent);
  final text = _textTheme(scheme.onSurface);
  final tabular = const [FontFeature.tabularFigures()];
  final shape = RoundedRectangleBorder(borderRadius: Shapes.cardRadius);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: fontFamily,
    textTheme: text,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    splashFactory: InkSparkle.splashFactory,
    extensions: [
      RambleTextStyles(
        result: text.headlineSmall!.copyWith(
          fontVariations: _axes(560, 24, grade: brightness == Brightness.dark ? -25 : 0),
          height: 1.4,
          letterSpacing: 0,
        ),
        timer: text.titleLarge!.copyWith(fontFeatures: tabular),
        timerLarge: text.displaySmall!.copyWith(
          fontFeatures: tabular,
          fontVariations: _axes(500, 36),
        ),
      ),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: shape,
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: text.labelLarge,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      labelType: NavigationRailLabelType.all,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Shapes.medium)),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: Shapes.sheetRadius),
      backgroundColor: scheme.surfaceContainerHigh,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Shapes.extraLarge))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Shapes.medium),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Shapes.medium),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    listTileTheme: ListTileThemeData(
      minVerticalPadding: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Shapes.medium)),
    ),
    focusColor: scheme.primary.withValues(alpha: 0.16),
    tooltipTheme: TooltipThemeData(waitDuration: const Duration(milliseconds: 500)),
  );
}

/// Expressive component theme derived from the same [ThemeData].
M3EThemeData buildM3eTheme(ThemeData theme) => M3EThemeData.fromMaterial(theme);

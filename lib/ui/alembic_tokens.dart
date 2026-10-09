import 'package:arcane/arcane.dart';

class AlembicShadcnTokens {
  static Color warning(ThemeData theme) =>
      theme.colorScheme.brightness == Brightness.dark
          ? const Color(0xFFE9B85C)
          : const Color(0xFF805500);
  static Color success(ThemeData theme) =>
      theme.colorScheme.brightness == Brightness.dark
          ? const Color(0xFF80CBB8)
          : const Color(0xFF216B58);
  static const EdgeInsets shellPadding = EdgeInsets.all(16);
  static const EdgeInsets surfacePadding = EdgeInsets.all(20);
  static const EdgeInsets compactSurfacePadding = EdgeInsets.all(10);
  static const EdgeInsets controlPadding =
      EdgeInsets.symmetric(horizontal: 12, vertical: 8);
  static const EdgeInsets compactControlPadding =
      EdgeInsets.symmetric(horizontal: 10, vertical: 6);
  static const EdgeInsets rowPadding =
      EdgeInsets.symmetric(horizontal: 14, vertical: 12);
  static const double surfaceRadius = 10;
  static const double controlRadius = 6;
  static const double badgeRadius = 4;
  static const double shellMaxWidth = double.infinity;
  static const double modalMaxWidth = 640;
  static const double listRowMaxWidth = double.infinity;
  static const double listRowHeight = 108;
  static const double listDescriptionLineHeight = 18;
  static const double sidebarWidth = 214;
  static const double asideWidth = 280;
  static const double controlHeight = 38;
  static const double compactButtonHeight = 32;
  static const double iconButtonSize = 38;
  static const double compactIconButtonSize = 34;
  static const double buttonMinWidth = 72;
  static const double compactButtonMinWidth = 56;
  static const double commandButtonWidth = 104;
  static const double commandIconWidth = 36;
  static const double dropdownMenuMaxHeight = 420;
  static const double macTitlebarInset = 12;
  static const double gapXs = 4;
  static const double gapSm = 8;
  static const double gapMd = 12;
  static const double gapLg = 16;
  static const double gapXl = 24;

  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF242424),
    card: Color(0xFFFFFFFF),
    cardForeground: Color(0xFF242424),
    popover: Color(0xFFFFFFFF),
    popoverForeground: Color(0xFF242424),
    primary: Color(0xFF505055),
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFFE8E8ED),
    secondaryForeground: Color(0xFF38383D),
    muted: Color(0xFFF2F2F7),
    mutedForeground: Color(0xFF626268),
    accent: Color(0xFFE5E5E9),
    accentForeground: Color(0xFF3A3A3F),
    destructive: Color(0xFFB42335),
    border: Color(0xFFDDDDDF),
    input: Color(0xFF85858B),
    ring: Color(0xFF505055),
    chart1: Color(0xFF626268),
    chart2: Color(0xFF26776A),
    chart3: Color(0xFF946823),
    chart4: Color(0xFF74747C),
    chart5: Color(0xFFACACB4),
    sidebar: Color(0xFFEDEDF0),
    sidebarForeground: Color(0xFF242424),
    sidebarPrimary: Color(0xFF626268),
    sidebarPrimaryForeground: Color(0xFFFFFFFF),
    sidebarAccent: Color(0xFFDADAE0),
    sidebarAccentForeground: Color(0xFF3A3A3F),
    sidebarBorder: Color(0xFFDDDDDF),
    sidebarRing: Color(0xFF626268),
  );

  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,
    background: Color(0xFF1E1E1E),
    foreground: Color(0xFFF0F0F2),
    card: Color(0xFF262626),
    cardForeground: Color(0xFFF0F0F2),
    popover: Color(0xFF222224),
    popoverForeground: Color(0xFFF0F0F2),
    primary: Color(0xFF707076),
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFF38383A),
    secondaryForeground: Color(0xFFE6E6E9),
    muted: Color(0xFF2C2C2E),
    mutedForeground: Color(0xFFAEAEB4),
    accent: Color(0xFF424246),
    accentForeground: Color(0xFFE4E4E8),
    destructive: Color(0xFFFF8693),
    border: Color(0xFF424244),
    input: Color(0xFF7D7D85),
    ring: Color(0xFFB4B4BA),
    chart1: Color(0xFFB4B4BA),
    chart2: Color(0xFF80CBB8),
    chart3: Color(0xFFD9B26A),
    chart4: Color(0xFFAEAEB4),
    chart5: Color(0xFF74747C),
    sidebar: Color(0xFF28282A),
    sidebarForeground: Color(0xFFF0F0F2),
    sidebarPrimary: Color(0xFFB4B4BA),
    sidebarPrimaryForeground: Color(0xFFFFFFFF),
    sidebarAccent: Color(0xFF414145),
    sidebarAccentForeground: Color(0xFFE4E4E8),
    sidebarBorder: Color(0xFF424244),
    sidebarRing: Color(0xFFB4B4BA),
  );

  static const ContrastedColorScheme scheme =
      ContrastedColorScheme(light: lightScheme, dark: darkScheme);
}

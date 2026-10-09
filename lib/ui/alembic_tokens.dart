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
  static const double sidebarWidth = 264;
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
    background: Color(0xFFF5F6F8),
    foreground: Color(0xFF20242C),
    card: Color(0xFFFFFFFF),
    cardForeground: Color(0xFF20242C),
    popover: Color(0xFFFFFFFF),
    popoverForeground: Color(0xFF20242C),
    primary: Color(0xFF16458F),
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFFEBEDF1),
    secondaryForeground: Color(0xFF343B47),
    muted: Color(0xFFF0F1F4),
    mutedForeground: Color(0xFF626B79),
    accent: Color(0xFFE7EDF8),
    accentForeground: Color(0xFF163F80),
    destructive: Color(0xFFB42335),
    border: Color(0xFFDCE0E6),
    input: Color(0xFF84909F),
    ring: Color(0xFF16458F),
    chart1: Color(0xFF16458F),
    chart2: Color(0xFF26776A),
    chart3: Color(0xFF946823),
    chart4: Color(0xFF63758B),
    chart5: Color(0xFFA9B7C8),
    sidebar: Color(0xFFF0F1F4),
    sidebarForeground: Color(0xFF20242C),
    sidebarPrimary: Color(0xFF16458F),
    sidebarPrimaryForeground: Color(0xFFFFFFFF),
    sidebarAccent: Color(0xFFE7EDF8),
    sidebarAccentForeground: Color(0xFF163F80),
    sidebarBorder: Color(0xFFDCE0E6),
    sidebarRing: Color(0xFF16458F),
  );

  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,
    background: Color(0xFF121417),
    foreground: Color(0xFFF0F1F4),
    card: Color(0xFF1A1D22),
    cardForeground: Color(0xFFF0F1F4),
    popover: Color(0xFF22262D),
    popoverForeground: Color(0xFFF0F1F4),
    primary: Color(0xFF174A9B),
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFF282D35),
    secondaryForeground: Color(0xFFE6E9EF),
    muted: Color(0xFF22262D),
    mutedForeground: Color(0xFFA6ADB9),
    accent: Color(0xFF202E48),
    accentForeground: Color(0xFFC3D2EF),
    destructive: Color(0xFFFF8693),
    border: Color(0xFF343A44),
    input: Color(0xFF727D8D),
    ring: Color(0xFF7D9FD9),
    chart1: Color(0xFF174A9B),
    chart2: Color(0xFF80CBB8),
    chart3: Color(0xFFD9B26A),
    chart4: Color(0xFFA6ADB9),
    chart5: Color(0xFF63758B),
    sidebar: Color(0xFF16191E),
    sidebarForeground: Color(0xFFF0F1F4),
    sidebarPrimary: Color(0xFF174A9B),
    sidebarPrimaryForeground: Color(0xFFFFFFFF),
    sidebarAccent: Color(0xFF202E48),
    sidebarAccentForeground: Color(0xFFC3D2EF),
    sidebarBorder: Color(0xFF343A44),
    sidebarRing: Color(0xFF7D9FD9),
  );

  static const ContrastedColorScheme scheme =
      ContrastedColorScheme(light: lightScheme, dark: darkScheme);
}

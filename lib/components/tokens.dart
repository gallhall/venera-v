part of 'components.dart';

/// Corner radii. Pick by role, not by look.
abstract final class AppRadius {
  static const double xs = 4; // progress bars, tiny tags/badges, drag handles
  static const double sm = 8; // covers and thumbnails, chips, small buttons, menu entries
  static const double md = 12; // text fields, anchored menus, highlighted list rows, image tiles
  static const double lg = 16; // cards (AppCard), comment bubbles, grouped panels
  static const double xl = 28; // dialogs, bottom sheets, side panels, pop-up windows
  static const double pill = 999; // fully rounded: search bars, pill buttons, floating pills
}

/// 4-dp spacing steps for new code.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;

  /// Horizontal page gutter.
  static const double gutter = 16;
}

/// Shared animation timings.
abstract final class AppDuration {
  static const fast = Duration(milliseconds: 160);
}

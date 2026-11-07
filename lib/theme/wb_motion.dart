import 'package:flutter/widgets.dart';

/// WorkBuddy canonical motion design tokens extracted from WorkBuddy's
/// design system (`--wb-motion-*` & component-level transition specs).
///
/// Key principle:
/// - **Asymmetric panel & modal transitions**:
///   - Opening / entering uses [durationMedium] (`200ms`) with [decelerate]
///     (`cubic-bezier(0.0, 0.0, 0.2, 1.0)`), so elements arrive immediately
///     and settle smoothly without sluggish startup.
///   - Closing / exiting uses [durationFast] (`150ms`) with [accelerate]
///     (`cubic-bezier(0.4, 0.0, 1.0, 1.0)`), so dismissed surfaces get out
///     of the user's way crisply.
/// - **Collapsible sections (`.cr-collapse__content`, `.height-section-motion`)**:
///   - Expanding uses [durationExpand] (`280ms`) with [collapseContent]
///     (`cubic-bezier(0.33, 1.0, 0.68, 1.0)`).
///   - Collapsing uses [durationCollapse] (`180ms`) with [collapseContent].
/// - **Micro-interactions & segmented thumbs (`.wb-segmented__thumb`)**:
///   - Uses [durationFast] (`150ms`) with [standard]
///     (`cubic-bezier(0.4, 0.0, 0.2, 1.0)`).
abstract final class WbMotion {
  // ── Durations (`--wb-motion-duration-*`) ──────────────────────────────────

  /// `--wb-motion-duration-instant: .1s` (hover/press feedback, icon color)
  static const Duration durationInstant = Duration(milliseconds: 100);

  /// `--wb-motion-duration-fast: .15s` / `--wb-motion-duration-sm: .15s`
  /// Used for closing panels/modals, segmented pill thumb, switch thumb,
  /// and tab inkbar transitions.
  static const Duration durationFast = Duration(milliseconds: 150);

  /// `--wb-motion-duration-collapse: .18s`
  /// Used when collapsing `.conversation-section-motion` and `.height-section-motion`.
  static const Duration durationCollapse = Duration(milliseconds: 180);

  /// `--wb-motion-duration-medium: .2s` / `--wb-motion-duration-base: .2s`
  /// Used for opening left sidebar, right detail panel, modals, and popovers.
  static const Duration durationMedium = Duration(milliseconds: 200);

  /// `--wb-drawer-panel-duration-exit: .22s`
  static const Duration durationDrawerExit = Duration(milliseconds: 220);

  /// `.cr-collapse__icon` rotation duration (`.24s`)
  static const Duration durationChevron = Duration(milliseconds: 240);

  /// `--wb-drawer-panel-duration-enter: .28s` & `.cr-collapse__content` expand (`.28s`)
  static const Duration durationExpand = Duration(milliseconds: 280);

  /// `--wb-motion-duration-gentle: .3s` / `--wb-motion-duration-md: .3s`
  /// Used for subagent/tab view transitions.
  static const Duration durationGentle = Duration(milliseconds: 300);

  /// `--wb-motion-duration-slow: .4s`
  static const Duration durationSlow = Duration(milliseconds: 400);

  // ── Easing Curves (`--wb-motion-easing-*`) ────────────────────────────────

  /// `--wb-motion-easing-standard: cubic-bezier(.4, 0, .2, 1)`
  /// Symmetric motion within screen bounds (segmented thumb, tab inkbar, switch).
  static const Curve standard = Cubic(0.4, 0.0, 0.2, 1.0);

  /// `--wb-motion-easing-decelerate: cubic-bezier(0, 0, .2, 1)`
  /// Opening panels (`sidebar-next-panel-motion-opening`, `detail-panel-motion-opening`),
  /// entering modals, and revealing elements.
  static const Curve decelerate = Cubic(0.0, 0.0, 0.2, 1.0);

  /// `--wb-motion-easing-accelerate: cubic-bezier(.4, 0, 1, 1)`
  /// Closing panels (`sidebar-next-panel-motion-closing`, `detail-panel-motion-closing`)
  /// and exiting modals/popovers.
  static const Curve accelerate = Cubic(0.4, 0.0, 1.0, 1.0);

  /// `--wb-motion-easing-emphasized: cubic-bezier(.2, 0, 0, 1)`
  /// Settings modal `slideUp`, drawer enter, and primary stage transitions.
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  /// `.cr-collapse__content` & `.height-section-motion`:
  /// `cubic-bezier(.33, 1, .68, 1)`
  static const Curve collapseContent = Cubic(0.33, 1.0, 0.68, 1.0);

  /// `.cr-collapse__icon`:
  /// `cubic-bezier(.2, .8, .2, 1)`
  static const Curve collapseIcon = Cubic(0.2, 0.8, 0.2, 1.0);

  /// `.cr-context-usage-popover__surface` / `cr-input-popover-expand`:
  /// `cubic-bezier(.16, 1, .3, 1)`
  static const Curve popoverExpand = Cubic(0.16, 1.0, 0.3, 1.0);

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Returns WorkBuddy's asymmetric panel duration (`200ms` open, `150ms` close).
  static Duration panelDuration({required bool open}) =>
      open ? durationMedium : durationFast;

  /// Returns WorkBuddy's asymmetric panel curve ([decelerate] open, [accelerate] close).
  static Curve panelCurve({required bool open}) =>
      open ? decelerate : accelerate;

  /// Returns WorkBuddy's asymmetric section height duration (`280ms` expand, `180ms` collapse).
  static Duration sectionDuration({required bool expand}) =>
      expand ? durationExpand : durationCollapse;
}

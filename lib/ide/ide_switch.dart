import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'ide_motion.dart';

/// A setting that is on or off: a switch, in the theme's button colors when
/// on. The one switch the app draws, wherever it appears: the settings'
/// rows, a menu's toggles, the MCP servers' panel.
///
/// Implements an elastic squash-and-stretch knob (`elastic-toggle`): while
/// sliding between off (`0`) and on (`1`), or while held down, the knob
/// widens into a capsule and rebounds to a circle as it lands.
class IdeSwitch extends StatefulWidget {
  const IdeSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.enabled = true,
    this.height = defaultHeight,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String semanticLabel;
  final bool enabled;

  /// How tall it stands: the row's label's height, as the settings' rows
  /// take it (see SettingsText.label), a menu's less.
  final double height;

  /// Beside a 13pt label, as the settings' rows have them.
  static const defaultHeight = 16.0;

  @override
  State<IdeSwitch> createState() => _IdeSwitchState();
}

class _IdeSwitchState extends State<IdeSwitch> {
  bool _pressed = false;

  /// What a switch off puts its knob in: `SettingsColors.textSecondary`'s
  /// color, which the settings' rows read (this draws it, that names it).
  static Color get _knobOff {
    final foreground = themeColors['editor.foreground'];
    final strength = themeColors.highContrast ? 0.84 : 0.74;
    return foreground.withValues(alpha: foreground.a * strength);
  }

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    final value = widget.value;
    final enabled = widget.enabled;
    final height = widget.height;
    final width = (height * 1.75).roundToDouble();
    final knobSize = height - 4;
    final trackOff = AppColors.textFaint.withValues(alpha: 0.45);
    final trackOn = colors['button.background'];
    final knobOff = _knobOff;
    final knobOn = colors['button.foreground'];

    return Semantics(
      toggled: value,
      enabled: enabled,
      label: widget.semanticLabel,
      excludeSemantics: true,
      onTap: enabled ? () => widget.onChanged(!value) : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        child: Listener(
          onPointerDown: enabled
              ? (_) => setState(() => _pressed = true)
              : null,
          onPointerUp: enabled
              ? (_) => setState(() => _pressed = false)
              : null,
          onPointerCancel: enabled
              ? (_) => setState(() => _pressed = false)
              : null,
          child: GestureDetector(
            onTap: enabled ? () => widget.onChanged(!value) : null,
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: value ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 220),
                curve: IdeMotion.easeOut,
                builder: (context, t, _) {
                  final clamped = t.clamp(0.0, 1.0);
                  // Mid-travel stretch (`sin(t * pi)`) + press hold stretch.
                  final travelStretch = math.sin(clamped * math.pi) * 0.34;
                  final pressStretch = _pressed ? 0.18 : 0.0;
                  final knobWidth =
                      knobSize * (1.0 + math.max(travelStretch, pressStretch));
                  return Container(
                    width: width,
                    height: height,
                    padding: const EdgeInsets.all(2),
                    alignment: Alignment(clamped * 2 - 1, 0),
                    decoration: BoxDecoration(
                      color: Color.lerp(trackOff, trackOn, clamped),
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                    child: Container(
                      width: knobWidth,
                      height: knobSize,
                      decoration: BoxDecoration(
                        color: Color.lerp(knobOff, knobOn, clamped),
                        borderRadius: BorderRadius.circular(knobSize / 2),
                        boxShadow: const [
                          BoxShadow(color: Color(0x33000000), blurRadius: 2),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

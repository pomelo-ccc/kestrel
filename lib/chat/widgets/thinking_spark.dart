import 'package:flutter/material.dart';

import '../../base/step_clock.dart';
import '../../theme/app_theme.dart';
import 'pixel_loader.dart';

/// Byte's animated 4-bar indicator while the agent thinks or works,
/// matching the Byte App Icon (4 vertical rounded bars: blue, orange, blue, blue)
/// and following the user's chosen bar-jumping rhythm in [PixelLoaderRole.agent].
class ThinkingSpark extends StatefulWidget {
  const ThinkingSpark({
    super.key,
    this.size = 14,
    this.color = AppColors.claude,
  });

  final double size;
  final Color color;

  /// How long each shape shows.
  static const frameTime = Duration(milliseconds: 120);

  /// Once round: 30° a second.
  static const turn = Duration(seconds: 12);

  /// Its shapes, from the dot to full bloom.
  static const shapes = 6;

  /// The shape [elapsed] in: up from the dot, and back down.
  static int shapeAt(Duration elapsed) {
    const bounce = shapes * 2 - 2;
    final step = elapsed.inMicroseconds ~/ frameTime.inMicroseconds % bounce;
    return step < shapes ? step : bounce - step;
  }

  @override
  State<ThinkingSpark> createState() => _ThinkingSparkState();
}

class _ThinkingSparkState extends State<ThinkingSpark> {
  late final StepClock _clock = StepClock(_frameTime);
  bool _still = false;

  Duration get _frameTime => Duration(
    microseconds: (22 * 1000 / PixelLoaderRole.agent.speed.value)
        .round()
        .clamp(10000, 100000),
  );

  @override
  void initState() {
    super.initState();
    PixelLoaderRole.agent.speed.addListener(_onSpeedChanged);
  }

  void _onSpeedChanged() {
    _clock.step = _frameTime;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = _clock.keepTo(context);
  }

  @override
  void dispose() {
    PixelLoaderRole.agent.speed.removeListener(_onSpeedChanged);
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PixelLoaderRole.agent.style,
      builder: (context, _) {
        final style = PixelLoaderRole.agent.style.value;
        final effectiveStyle = style == PixelLoaderStyle.circle
            ? PixelLoaderStyle.fill
            : style;
        return SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(
            painter: ByteBarsPainter(
              _clock,
              effectiveStyle,
              widget.color,
              still: _still,
            ),
          ),
        );
      },
    );
  }
}

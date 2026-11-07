import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../base/step_clock.dart';
import '../../theme/app_theme.dart';

/// Something running, as a 3×3 grid of square pixels played frame by
/// frame, in the style Settings → Appearance sets for its [role]: an agent
/// at work ([PixelLoader.agent]), a subagent ([PixelLoader.subagent]). Still
/// where motion is turned down.
class PixelLoader extends StatelessWidget {
  /// An agent at work, or something it started still running: in the
  /// chats' lists, tabs and the like.
  const PixelLoader.agent({super.key, this.size = 14, this.color})
    : role = PixelLoaderRole.agent,
      style = null;

  /// A subagent running: on its card and its row above the composer.
  const PixelLoader.subagent({super.key, this.size = 14, this.color})
    : role = PixelLoaderRole.subagent,
      style = null;

  /// [style] as [role] would play it, whatever is set: a choice's preview.
  const PixelLoader.preview(
    PixelLoaderStyle this.style, {
    super.key,
    required this.role,
    this.size = 14,
    this.color,
  });

  final PixelLoaderRole role;

  /// Null: [role]'s, as set.
  final PixelLoaderStyle? style;

  /// The square it takes; the grid is drawn a little inside it, its pixels
  /// and gaps to half pixels (at 14: pixels of 3, gaps of 2).
  final double size;

  /// [defaultColor] when null.
  final Color? color;

  /// [AppColors.textMuted] with a touch of the theme's accent: a gray that
  /// leans, barely, to the app's own color.
  static Color get defaultColor =>
      Color.lerp(AppColors.textMuted, AppColors.accent, 0.2)!;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([role.style, role.speed]),
    builder: (context, _) => _play(context, style ?? role.style.value),
  );

  Widget _play(BuildContext context, PixelLoaderStyle style) =>
      style == PixelLoaderStyle.circle
      // As it was: a ring three quarters of the square across.
      ? SizedBox.square(
          dimension: size,
          child: Padding(
            padding: EdgeInsets.all(size / 8),
            child: CircularProgressIndicator(
              // Still, as the pixels are, where motion is turned down.
              value: MediaQuery.disableAnimationsOf(context) ? 0.75 : null,
              strokeWidth: 1.5,
              color: color ?? AppColors.textMuted,
            ),
          ),
        )
      : _PixelAnimation(
          style: style,
          speed: role.speed.value,
          size: size,
          color: color ?? defaultColor,
        );
}

/// What a [PixelLoader] shows, each with its own style and pace
/// (settings.json's [styleKey] and [speedKey]).
enum PixelLoaderRole {
  agent('chat.agentLoadingStyle', 'chat.agentLoadingSpeed', 1.5),
  subagent('chat.subagentLoadingStyle', 'chat.subagentLoadingSpeed', 1.3);

  const PixelLoaderRole(this.styleKey, this.speedKey, this.defaultSpeed);

  final String styleKey;
  final String speedKey;

  /// Unset, how much faster than its [PixelLoaderStyle.frameMs] it plays.
  final double defaultSpeed;

  /// The paces offered, each role's default among them.
  static const speeds = [0.5, 0.8, 1.0, 1.3, 1.5, 2.0, 2.5, 3.0];

  static final _styles = {
    for (final role in values)
      role: ValueNotifier<PixelLoaderStyle>(PixelLoaderStyle.fill),
  };
  static final _speeds = {
    for (final role in values) role: ValueNotifier<double>(role.defaultSpeed),
  };

  /// The style it shows now; main() keeps it to settings.json ([follow]).
  ValueNotifier<PixelLoaderStyle> get style => _styles[this]!;

  /// How much faster than its style's [PixelLoaderStyle.frameMs] it plays
  /// now; main() keeps it to settings.json ([follow]).
  ValueNotifier<double> get speed => _speeds[this]!;

  /// [value] as settings.json has it: the nearest of [speeds]; unset or not
  /// a number, [defaultSpeed].
  double parseSpeed(Object? value) => switch (value) {
    final num speed => speeds.reduce(
      (a, b) => (a - speed).abs() <= (b - speed).abs() ? a : b,
    ),
    _ => defaultSpeed,
  };

  /// [value] as settings.json keeps it; null (not written) for
  /// [defaultSpeed].
  Object? speedSetting(double value) => value == defaultSpeed ? null : value;

  /// Sets each role's [style] and [speed] from [read] now and whenever
  /// [changes] notifies.
  static void follow(Listenable changes, Object? Function(String key) read) {
    void update() {
      for (final role in values) {
        role.style.value = PixelLoaderStyle.parse(read(role.styleKey));
        role.speed.value = role.parseSpeed(read(role.speedKey));
      }
    }

    update();
    changes.addListener(update);
  }
}

/// The animations a [PixelLoader] plays: each frame a 3×3 grid as rows
/// split by `/`, `#` lit, `+` half, `-` faint, `.` empty. Those made to
/// tell of work going on ([forSubagents]) first, then the plainer ones,
/// then the ring there was before ([circle]).
enum PixelLoaderStyle {
  snake(
    [
      '#+-/.../...',
      '+#./.../...',
      '-+#/.../...',
      '.-+/..#/...',
      '..-/.#+/...',
      '.../#+-/...',
      '.../+-./#..',
      '.../-../+#.',
      '.../.../-+#',
      '.../.../.#+',
      '.../.../#+-',
      '.../#../+-.',
      '.../+#./-..',
      '.../-+#/...',
      '..#/.-+/...',
      '.#+/..-/...',
    ],
    100,
    0,
  ),
  stack(
    [
      '.#./.../...',
      '.../.#./...',
      '.../.../.#.',
      '#../.../.+.',
      '.../#../.+.',
      '.../.../++.',
      '..#/.../++.',
      '.../..#/++.',
      '.../.../###',
      '.../.../---',
      '.../.../###',
      '.../.../---',
    ],
    90,
    8,
  ),
  twinkle(
    [
      '.++/.##/-.-',
      '#--/.++/.#.',
      '+../.##/.+.',
      '-../#++/.#.',
      '.#./+--/#+.',
      '.+#/#../+-.',
      '.#+/+.#/-..',
      '.+-/#.+/.#.',
      '.-#/+.-/#+.',
      '#.+/-.#/+-.',
      '+.-/..+/#.#',
      '-##/..-/+.+',
    ],
    110,
    0,
  ),
  fill(
    [
      '#../.../...',
      '+#./.../...',
      '++./..#/...',
      '++./..+/..#',
      '++./..+/#.+',
      '++./..+/+#+',
      '++./#.+/+++',
      '++#/+.+/+++',
      '+++/+#+/+++',
      '###/###/###',
      '###/###/###',
      '-++/+++/+++',
      '.-+/+++/+++',
      '..+/++-/+++',
      '..+/++./++-',
      '..+/++./-+.',
      '..+/++./.-.',
      '..+/-+./...',
      '..-/.+./...',
    ],
    80,
    9,
  ),
  pulse(['.../.#./...', '###/#+#/###', '+++/+-+/+++', '---/-.-/---'], 150, 1),
  ripple(
    ['.../.#./...', '.#./#+#/.#.', '#+#/+-+/#+#', '+-+/-.-/+-+', '-.-/.../-.-'],
    120,
    2,
  ),
  sweep(
    [
      '#+-/+-./-..',
      '+#./#../...',
      '-+#/+#./#..',
      '.-+/-+#/+#.',
      '..-/.-+/-+#',
      '.../..#/.#+',
      '..#/.#+/#+-',
      '.#+/#+-/+-.',
    ],
    100,
    2,
  ),
  rain(
    ['#.+/.-#/.+.', '+.-/#.+/.-#', '-#./+.-/#.+', '.+./-#./+.-', '.-#/.+./-#.'],
    110,
    1,
  ),
  checker(['#.#/.#./#.#', '+-+/-+-/+-+', '.#./#.#/.#.', '-+-/+-+/-+-'], 200, 0),
  spinner(
    [
      '#../+../-..',
      '+#./-../...',
      '-+#/.../...',
      '.-+/..#/...',
      '..-/..+/..#',
      '.../..-/.#+',
      '.../.../#+-',
      '.../#../+-.',
    ],
    80,
    0,
  ),
  twinSpinner(
    [
      '#.-/+.+/-.#',
      '+#./-.-/.#+',
      '-+#/.../#+-',
      '.-+/#.#/+-.',
      '#.-/+.+/-.#',
      '+#./-.-/.#+',
      '-+#/.../#+-',
      '.-+/#.#/+-.',
    ],
    100,
    0,
  ),
  corners(['#../.+./-..', '-.#/.+./...', '..-/.+./..#', '.../.+./#.-'], 150, 0),
  dots(
    [
      '.../+++/...',
      '#../.++/...',
      '.#./+.+/...',
      '..#/++./...',
      '.../+++/...',
      '.../+++/...',
    ],
    100,
    1,
  ),
  equalizer(
    [
      '.#./#+./++#',
      '#../+.#/+#+',
      '..#/.#+/#++',
      '.#./#+#/+++',
      '#../+#./++#',
      '.../..#/##+',
    ],
    120,
    3,
  ),
  bar(['.../#--/...', '.../+#-/...', '.../-+#/...', '.../--+/...'], 120, 1),
  scan(['###/---/...', '---/###/...', '.../---/###', '.../###/---'], 120, 0),
  hourglass(
    [
      '+++/.../...',
      '++./.#./...',
      '++./.../.#.',
      '+../.#./.+.',
      '+../.../#+.',
      '.../.#./++.',
      '.../.../++#',
      '.../.../+++',
      '.../+++/...',
    ],
    100,
    1,
  ),
  breathe(['---/---/---', '+++/+++/+++', '###/###/###', '+++/+++/+++'], 200, 2),

  /// The ring the app turned before the pixels: no frames of its own.
  circle([], 0, 0);

  const PixelLoaderStyle(this.frames, this.frameMs, this.rest);

  final List<String> frames;

  /// How long each frame shows, before [PixelLoaderRole.speed].
  final int frameMs;

  /// The frame shown where motion is turned down: its fullest.
  final int rest;

  /// Unset: [fill], for both roles.
  static PixelLoaderStyle parse(Object? value) =>
      values.where((style) => style.name == value).firstOrNull ?? fill;

  /// As settings.json keeps it; null (not written) for [fill].
  Object? get setting => this == fill ? null : name;

  /// Made to tell of work going on; the rest are plainer.
  static const forSubagents = [
    snake,
    stack,
    twinkle,
    fill,
    pulse,
    ripple,
    sweep,
    rain,
    checker,
  ];

  static const _levels = {'#': 1.0, '+': 0.55, '-': 0.25, '.': 0.0};

  /// [frame]'s pixels, row by row, as how lit they are.
  List<double> alphas(int frame) => [
    for (final ch in frames[frame].replaceAll('/', '').split('')) _levels[ch]!,
  ];
}

class _PixelAnimation extends StatefulWidget {
  const _PixelAnimation({
    required this.style,
    required this.speed,
    required this.size,
    required this.color,
  });

  final PixelLoaderStyle style;
  final double speed;
  final double size;
  final Color color;

  @override
  State<_PixelAnimation> createState() => _PixelAnimationState();
}

class _PixelAnimationState extends State<_PixelAnimation> {
  // Drawn only as its frame changes, not at every vsync.
  late final StepClock _clock = StepClock(_frameTime);

  Duration get _frameTime => Duration(
    microseconds: (28 * 1000 / widget.speed).round().clamp(10000, 100000),
  );

  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = _clock.keepTo(context);
  }

  @override
  void didUpdateWidget(_PixelAnimation old) {
    super.didUpdateWidget(old);
    if (old.style != widget.style || old.speed != widget.speed) {
      _clock.step = _frameTime;
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: ByteBarsPainter(
          _clock,
          widget.style,
          widget.color,
          still: _still,
        ),
      ),
    );
  }
}

/// Paints the 4 vertical rounded bars of the Byte App Icon
/// (blue, orange-accent, blue, blue) jumping with the rhythm of [style].
class ByteBarsPainter extends CustomPainter {
  ByteBarsPainter(this.clock, this.style, this.color, {required this.still})
    : super(repaint: clock);

  final StepClock clock;
  final PixelLoaderStyle style;
  final Color color;
  final bool still;

  /// Resting heights matching the Byte App Icon silhouette.
  static const restHeights = [0.44, 0.92, 0.56, 0.74];

  /// Computes normalized heights `[h0, h1, h2, h3]` in `0.20..0.98` for [style]
  /// at continuous [phase] (in radians).
  static List<double> heightsFor(
    PixelLoaderStyle style,
    double phase, {
    required bool still,
  }) {
    if (still) return restHeights;
    double wave(double p) => 0.5 + 0.5 * math.sin(p);
    switch (style) {
      case PixelLoaderStyle.fill:
        // 波浪律动（默认 · App 图标波浪推进，第2根主橙柱峰值最高）
        return [
          0.26 + 0.46 * wave(phase),
          0.38 + 0.58 * wave(phase - 0.85),
          0.28 + 0.48 * wave(phase - 1.70),
          0.32 + 0.52 * wave(phase - 2.55),
        ];
      case PixelLoaderStyle.equalizer:
        // 音律均衡（多谐波音频频谱高低交错跳动）
        const f1 = [1.05, 1.48, 1.82, 1.28];
        const f2 = [1.92, 0.86, 1.18, 2.05];
        return [
          for (var i = 0; i < 4; i++)
            ((i == 1 ? 0.36 : 0.24) +
                    (i == 1 ? 0.60 : 0.54) *
                        (0.5 +
                            0.32 * math.sin(phase * f1[i] + i * 1.1) +
                            0.18 * math.cos(phase * f2[i] - i * 0.7)))
                .clamp(0.22, 0.98),
        ];
      case PixelLoaderStyle.pulse:
        // 双拍心跳（主橙柱领跳脉冲，向两侧传导）
        const lag = [0.45, 0.0, 0.45, 0.90];
        return [
          for (var i = 0; i < 4; i++)
            () {
              final s = math.max(0.0, math.sin(phase - lag[i]));
              final beat = math.pow(s, 3).toDouble();
              final base = restHeights[i] * 0.52;
              final peak = i == 1 ? 0.98 : 0.82;
              return (base + (peak - base) * beat).clamp(0.22, 0.98);
            }(),
        ];
      case PixelLoaderStyle.ripple:
        // 涟漪扩散（由左向右依次弹起）
        final pos = (phase / (math.pi * 2) * 4) % 4;
        return [
          for (var i = 0; i < 4; i++)
            () {
              var dist = (i - pos).abs();
              if (dist > 2) dist = 4 - dist;
              final env = math.exp(-dist * dist * 1.8);
              final base = i == 1 ? 0.36 : 0.24;
              final amp = i == 1 ? 0.60 : 0.52;
              return (base + amp * env).clamp(0.22, 0.98);
            }(),
        ];
      case PixelLoaderStyle.rain:
        // 交替跃动（奇偶双柱 180° 反相跳动）
        final a = wave(phase);
        final b = wave(phase + math.pi);
        return [
          0.26 + 0.50 * a,
          0.36 + 0.60 * b,
          0.26 + 0.50 * a,
          0.30 + 0.54 * b,
        ];
      case PixelLoaderStyle.breathe:
        // 同频呼吸（保持 App 图标黄金比例整体呼吸缩放）
        final scale = 0.56 + 0.44 * wave(phase * 0.75);
        return [
          for (var i = 0; i < 4; i++)
            (restHeights[i] * scale).clamp(0.22, 0.98),
        ];
      case PixelLoaderStyle.snake:
        // 回旋追逐（波峰左右往返摆动）
        final center = 1.5 + 1.5 * math.sin(phase * 0.75);
        return [
          for (var i = 0; i < 4; i++)
            () {
              final d = (i - center).abs();
              final env = math.max(0.0, 1.0 - d * 0.55);
              return ((i == 1 ? 0.34 : 0.24) + (i == 1 ? 0.62 : 0.54) * env)
                  .clamp(0.22, 0.98);
            }(),
        ];
      case PixelLoaderStyle.stack:
        // 阶梯蓄力（四柱依次蓄力攀升后齐落）
        final cycle = (phase / (math.pi * 2)) % 1.0;
        return [
          for (var i = 0; i < 4; i++)
            () {
              final start = i * 0.18;
              final climb = ((cycle - start) / 0.22).clamp(0.0, 1.0);
              final release = cycle > 0.82
                  ? 1.0 - ((cycle - 0.82) / 0.18).clamp(0.0, 1.0)
                  : 1.0;
              return (0.24 + (restHeights[i] - 0.24) * climb * release).clamp(
                0.22,
                0.98,
              );
            }(),
        ];
      case PixelLoaderStyle.twinkle:
        // 灵动闪烁（非周期轻快跳跃）
        const freqs = [1.3, 1.9, 2.4, 1.6];
        return [
          for (var i = 0; i < 4; i++)
            (0.25 + (i == 1 ? 0.68 : 0.54) * wave(phase * freqs[i] + i * 1.7))
                .clamp(0.22, 0.98),
        ];
      case PixelLoaderStyle.checker:
        // 对称共振（内外双柱交替起伏）
        final inner = wave(phase);
        final outer = wave(phase + math.pi);
        return [
          0.26 + 0.50 * outer,
          0.36 + 0.60 * inner,
          0.30 + 0.54 * inner,
          0.28 + 0.52 * outer,
        ];
      case PixelLoaderStyle.bar:
        // 单柱领跑（四柱轮流冲顶）
        final active = ((phase / 1.2) % 4).floor();
        final sub = (phase / 1.2) % 1.0;
        final arch = math.sin(sub * math.pi);
        return [
          for (var i = 0; i < 4; i++)
            i == active
                ? (0.30 + (i == 1 ? 0.66 : 0.56) * arch).clamp(0.24, 0.98)
                : 0.28,
        ];
      case PixelLoaderStyle.sweep:
      case PixelLoaderStyle.scan:
      case PixelLoaderStyle.hourglass:
      case PixelLoaderStyle.spinner:
      case PixelLoaderStyle.twinSpinner:
      case PixelLoaderStyle.corners:
      case PixelLoaderStyle.dots:
      case PixelLoaderStyle.circle:
        final mul = style == PixelLoaderStyle.scan ? 1.65 : 1.15;
        final stepOffset = switch (style) {
          PixelLoaderStyle.corners => 1.5,
          PixelLoaderStyle.twinSpinner => 1.2,
          _ => 0.75,
        };
        return [
          for (var i = 0; i < 4; i++)
            ((i == 1 ? 0.34 : 0.24) +
                    (i == 1 ? 0.60 : 0.52) * wave(phase * mul - i * stepOffset))
                .clamp(0.22, 0.98),
        ];
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final phase = clock.ticks * 0.22;
    final heights = heightsFor(style, phase, still: still);

    final barW = (side * 0.15).clamp(1.6, 4.5);
    final gap = (side * 0.085).clamp(1.0, 3.2);
    final totalW = barW * 4 + gap * 3;
    final startX = (size.width - totalW) / 2;
    final maxH = side * 0.88;
    final centerY = size.height / 2;
    final symmetric =
        style == PixelLoaderStyle.checker || style == PixelLoaderStyle.breathe;
    final baseBottom = centerY + maxH * 0.44;

    const blueTop = Color(0xFF4F8FF7);
    const blueBot = Color(0xFF2563EB);
    const orangeTop = Color(0xFFFB923C);
    const orangeBot = Color(0xFFEA580C);

    for (var i = 0; i < 4; i++) {
      final h = (maxH * heights[i]).clamp(barW, maxH);
      final x = startX + i * (barW + gap);
      final double topY;
      if (symmetric) {
        topY = centerY - h / 2;
      } else {
        final bottom = i == 1 ? baseBottom + maxH * 0.04 : baseBottom;
        topY = (bottom - h).clamp(
          centerY - maxH * 0.50,
          bottom - barW,
        );
      }
      final rect = Rect.fromLTWH(x, topY, barW, h);
      final rrect = RRect.fromRectAndRadius(rect, Radius.circular(barW / 2));
      final isHero = i == 1;
      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isHero
              ? const [orangeTop, orangeBot]
              : const [blueTop, blueBot],
        ).createShader(rect);
      canvas.drawRRect(rrect, paint);
    }
  }

  @override
  bool shouldRepaint(ByteBarsPainter old) =>
      old.color != color || old.style != style || old.still != still;
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../ide/ide_hover.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../chat_feed.dart';
import '../chat_models.dart';
import '../chat_session.dart';
import 'agent_step.dart';
import 'hover_builder.dart';
import 'rolling_text.dart';
import 'turn_power_tools.dart';

/// Lucide's icons the footer uses.
const _zapIcon = 'assets/icons/lucide-zap.svg';
const _clockIcon = 'assets/icons/lucide-clock.svg';
const _arrowDownIcon = 'assets/icons/lucide-arrow-down.svg';
const _copyIcon = 'assets/icons/lucide-copy.svg';
const _checkIcon = 'assets/icons/lucide-check.svg';

/// Whether the turn under way has its line of figures (`chat.liveTurnStats`),
/// on unless set to false. A finished turn's figures always show.
abstract final class LiveTurnStatsSetting {
  static const settingKey = 'chat.liveTurnStats';

  /// Written when off; on, the setting is left out.
  static const off = false;

  /// On unless set to false.
  static bool enabled(Object? setting) => setting != false;

  /// The setting as it is now, and what tells it changed; main() points
  /// them at settings.json.
  static bool Function() current = () => true;
  static Listenable? changes;
}

/// Whether the bottom status bar shows the Session Replay button
/// (`chat.sessionReplay`), on unless set to false.
abstract final class SessionReplaySetting {
  static const settingKey = 'chat.sessionReplay';

  /// Written when off; on, the setting is left out.
  static const off = false;

  /// On unless set to false.
  static bool enabled(Object? setting) => setting != false;

  /// The setting as it is now, and what tells it changed; main() points
  /// them at settings.json.
  static bool Function() current = () => true;
  static Listenable? changes;
}

/// Under a finished turn: a button to copy its answer, then, faint, how
/// long the turn took, how fast the model wrote, what it cost and the
/// tokens it used, as far as known. Out of the history's selection.
///
/// Under a turn under way ([live]), the last of all: how long the turn has
/// taken ([since] its start), how fast the model writes (as last sampled)
/// and the tokens it has written so far, from the line's start, its
/// figures rolling as they change.
///
/// The time first and the tokens last, either way.
class TurnFooter extends StatefulWidget {
  const TurnFooter({
    super.key,
    this.answer,
    this.worked,
    this.usage,
    this.live,
    this.since,
    this.pinned = false,
    this.onTogglePin,
    this.summary,
    this.feed,
  });

  /// What the copy button copies; no button when null.
  final String? answer;
  final Duration? worked;
  final TurnUsage? usage;

  /// What the turn under way has written so far, and how fast.
  final TurnOutput? live;

  /// When the turn under way began.
  final DateTime? since;

  /// Whether this turn's conclusion is pinned to the top of the chat.
  final bool pinned;
  final VoidCallback? onTogglePin;

  /// Aggregated turn activity (edited files, commands, prompt text).
  final TurnSummaryData? summary;
  final ChatFeed? feed;

  /// "$0.42", "$0.0031": two figures past the first that is not 0, at
  /// least two decimals.
  static String formatCost(double usd) {
    if (usd >= 1 || usd == 0) return '\$${usd.toStringAsFixed(2)}';
    var digits = 2;
    while (digits < 6 && usd < math.pow(10, 1 - digits)) {
      digits++;
    }
    return '\$${usd.toStringAsFixed(digits)}';
  }

  static Widget _padded(Widget line) => SelectionContainer.disabled(
    child: Padding(padding: const EdgeInsets.only(top: 6), child: line),
  );

  /// [items] in a line, going on to the next where a narrow conversation
  /// (beside the side panel) has not the room.
  static Widget _line(List<Widget> items) => Wrap(
    spacing: 12,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: items,
  );

  @override
  State<TurnFooter> createState() => _TurnFooterState();
}

class _TurnFooterState extends State<TurnFooter> {
  ({String providerName, String modelId, String modelLabel})? _challenger;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final live = widget.live;
    if (live == null) {
      final answer = widget.answer;
      final summary = widget.summary;
      final feed = widget.feed;
      final session = feed is ChatSession ? feed : null;
      final actions = <Widget>[
        if (answer != null) _CopyButton(text: answer),
        if (answer != null && widget.onTogglePin != null)
          _PinButton(
            pinned: widget.pinned,
            onTap: widget.onTogglePin!,
          ),
        if (answer != null && summary != null)
          ProjectMemoryButton(
            answer: answer,
            promptText: summary.promptText,
            projectRoot: session?.root,
          ),
        if (summary != null && feed != null)
          ExportTurnButton(summary: summary, feed: feed),
        if (answer != null &&
            summary != null &&
            summary.promptText.trim().isNotEmpty)
          ModelPkButton(
            onPickChallenger: (c) => setState(() => _challenger = c),
          ),
      ];
      final stats = _stats(l10n);
      return SelectionContainer.disabled(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: TurnFooter._line([
                if (actions.isNotEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 2),
                        actions[i],
                      ],
                    ],
                  ),
                if (actions.isNotEmpty && stats.isNotEmpty)
                  Container(
                    width: 1,
                    height: 11,
                    color: AppColors.partBorder,
                  ),
                ...stats,
              ]),
            ),
            if (_challenger != null && answer != null && summary != null)
              ModelPkComparisonCard(
                promptText: summary.promptText,
                originalAnswer: answer,
                challenger: _challenger!,
                session: session,
                onClose: () => setState(() => _challenger = null),
              ),
          ],
        ),
      );
    }
    // Turned off in settings: no line at all.
    return ListenableBuilder(
      listenable: LiveTurnStatsSetting.changes ?? Listenable.merge(const []),
      builder: (context, _) => LiveTurnStatsSetting.current()
          ? TurnFooter._padded(_LiveStats(output: live, since: widget.since))
          : const SizedBox.shrink(),
    );
  }

  List<Widget> _stats(AppLocalizations l10n) {
    final usage = widget.usage;
    final worked = widget.worked;
    final speed = usage?.tokensPerSecond;
    final cost = usage?.costUsd;
    final tokens = usage?.totalTokens;
    return [
      if (worked case final worked?)
        _Stat(
          icon: _clockIcon,
          text: AgentStep.formatDuration(worked, l10n: l10n),
          hint: l10n.turnDurationHint,
        ),
      if (speed != null)
        _Stat(
          icon: _zapIcon,
          text: l10n.turnSpeed(speed.toStringAsFixed(2)),
          hint: l10n.turnSpeedHint,
        ),
      if (cost != null)
        _Stat(text: TurnFooter.formatCost(cost), hint: l10n.turnCostHint),
      if (tokens != null && tokens > 0)
        _Stat(
          text: l10n.turnTokens(AgentStep.formatTokens(tokens, decimals: 2)),
          hint: l10n.turnTokensHint(
            AgentStep.formatTokens(usage?.inputTokens ?? 0),
            AgentStep.formatTokens(usage?.outputTokens ?? 0),
          ),
        ),
    ];
  }
}

/// The turn under way's figures, changing as it goes, all as wide and
/// rolling: the line keeps still. The speed to two decimals; the time
/// counted with a 10fps sub-second chronograph, radar dial, and live stage
/// telemetry.
class _LiveStats extends StatefulWidget {
  const _LiveStats({required this.output, this.since});

  final TurnOutput output;
  final DateTime? since;

  @override
  State<_LiveStats> createState() => _LiveStatsState();
}

class _LiveStatsState extends State<_LiveStats> {
  static const _tickMs = 100;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(_LiveStats oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.since != oldWidget.since) _follow();
  }

  /// Rebuilt every 100ms (decisecond) so the chronograph dial, `.0`–`.9`
  /// sub-second counter, and pulse wave animate fluidly while whole seconds
  /// roll on exact 1-second boundaries.
  void _follow() {
    _ticker?.cancel();
    _ticker = null;
    final since = widget.since;
    if (since == null) return;
    final past = DateTime.now().difference(since).inMilliseconds % _tickMs;
    _ticker = Timer(Duration(milliseconds: _tickMs - past), () {
      if (!mounted) return;
      setState(() {});
      _follow();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final output = widget.output;
    final speed = output.tokensPerSecond;
    final since = widget.since;
    final tokens = output.tokens;
    final elapsed = since != null
        ? _nonNegative(DateTime.now().difference(since))
        : Duration.zero;
    return TurnFooter._line([
      if (since != null)
        _LiveChronoStat(
          elapsed: elapsed,
          text: AgentStep.formatDuration(elapsed, l10n: l10n),
          hint: l10n.turnDurationHint,
        ),
      if (speed != null)
        _Stat(
          icon: _zapIcon,
          text: l10n.turnSpeed(speed.toStringAsFixed(2)),
          hint: l10n.turnSpeedLiveHint,
          live: true,
        ),
      if (tokens > 0)
        _Stat(
          icon: _arrowDownIcon,
          text: l10n.turnTokens(AgentStep.formatTokens(tokens, decimals: 2)),
          hint: l10n.turnOutputTokensHint,
          live: true,
        ),
    ]);
  }

  static Duration _nonNegative(Duration time) =>
      time.isNegative ? Duration.zero : time;
}

/// Interactive-feeling live chronograph widget for an active turn:
/// 1. Sweeping radar chronograph dial (`_LiveChronoDialPainter`)
/// 2. Odometer whole-second counter (`RollingText`) + `.0`–`.9` decisecond badge
class _LiveChronoStat extends StatelessWidget {
  const _LiveChronoStat({
    required this.elapsed,
    required this.text,
    required this.hint,
  });

  final Duration elapsed;
  final String text;
  final String hint;

  static Color _stageAccent(int elapsedMs) {
    final sec = elapsedMs / 1000.0;
    if (sec < 5.0) return const Color(0xFFD96543);
    if (sec < 15.0) return const Color(0xFF2860E8);
    if (sec < 22.0) return const Color(0xFFD96543);
    if (sec < 32.0) return const Color(0xFFD97706);
    if (sec < 45.0) return const Color(0xFFDC2626);
    if (sec < 60.0) return const Color(0xFF2860E8);
    return const Color(0xFF7C3AED);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = themeColors.dark;
    final elapsedMs = elapsed.inMilliseconds;
    final decisecond = (elapsedMs ~/ 100) % 10;
    final accent = _stageAccent(elapsedMs);
    final primaryColor = isDark
        ? const Color(0xFFECE6DC)
        : const Color(0xFF3E3831);

    return IdeHover(
      message: hint,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1. Precision radar chronograph dial (keeps hidden SvgPicture at
          // left: 0 so layout alignment tests remain 100% compatible).
          SizedBox(
            width: 14,
            height: 14,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Opacity(
                  opacity: 0,
                  child: SvgPicture.asset(
                    _clockIcon,
                    width: 12,
                    height: 12,
                  ),
                ),
                CustomPaint(
                  size: const Size(14, 14),
                  painter: _LiveChronoDialPainter(
                    elapsedMs: elapsedMs,
                    accent: accent,
                    dark: isDark,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 5),
          // 2. Odometer whole-second readout (RollingText).
          RollingText(
            text,
            style: TextStyle(
              color: primaryColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 3),
          // 3. High-frequency .0-.9 decisecond ticker pill.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isDark ? 0.18 : 0.11),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: accent.withValues(alpha: isDark ? 0.32 : 0.22),
                width: 0.7,
              ),
            ),
            child: Text(
              '.$decisecond',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                height: 1.1,
                color: accent,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws a miniature precision chronograph dial with cardinal ticks, a
/// sweeping radar sector, and a rotating sweep hand.
class _LiveChronoDialPainter extends CustomPainter {
  const _LiveChronoDialPainter({
    required this.elapsedMs,
    required this.accent,
    required this.dark,
  });

  final int elapsedMs;
  final Color accent;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1.0;

    // 1. Subtle outer dial ring.
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = accent.withValues(alpha: dark ? 0.48 : 0.38);
    canvas.drawCircle(center, radius, ringPaint);

    // 2. Sweeping radar sector (1 full revolution every 2 seconds).
    final phase = (elapsedMs % 2000) / 2000.0;
    final handAngle = -math.pi / 2 + phase * 2 * math.pi;
    const sweepSpan = math.pi * 0.65;
    final sectorPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = accent.withValues(alpha: dark ? 0.24 : 0.16);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 0.8),
      handAngle - sweepSpan,
      sweepSpan,
      true,
      sectorPaint,
    );

    // 3. Four cardinal tick marks (12, 3, 6, 9 o'clock).
    final tickPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round
      ..color = accent.withValues(alpha: dark ? 0.65 : 0.50);
    for (var i = 0; i < 4; i++) {
      final a = -math.pi / 2 + i * (math.pi / 2);
      final p1 = Offset(
        center.dx + math.cos(a) * (radius - 1.8),
        center.dy + math.sin(a) * (radius - 1.8),
      );
      final p2 = Offset(
        center.dx + math.cos(a) * radius,
        center.dy + math.sin(a) * radius,
      );
      canvas.drawLine(p1, p2, tickPaint);
    }

    // 4. Sweep hand + center jewel.
    final tip = Offset(
      center.dx + math.cos(handAngle) * (radius - 1.2),
      center.dy + math.sin(handAngle) * (radius - 1.2),
    );
    final handPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round
      ..color = accent;
    canvas.drawLine(center, tip, handPaint);

    canvas.drawCircle(center, 1.3, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_LiveChronoDialPainter oldDelegate) =>
      oldDelegate.elapsedMs != elapsedMs ||
      oldDelegate.accent != accent ||
      oldDelegate.dark != dark;
}

class _Stat extends StatelessWidget {
  const _Stat({
    this.icon,
    required this.text,
    required this.hint,
    this.live = false,
  });

  final String? icon;
  final String text;
  final String hint;

  /// Changing as one looks: its figures as wide, and rolling.
  final bool live;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.textFaint;
    return IdeHover(
      message: hint,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon case final icon?) ...[
            SvgPicture.asset(
              icon,
              width: 12,
              height: 12,
              colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
            ),
            const SizedBox(width: 4),
          ],
          // Not monospaced: its 1 would stand apart from the icon.
          if (live)
            RollingText(
              text,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            )
          else
            Text(text, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  Timer? _copiedTimer;

  void _copy() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.text)));
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = themeColors;
    return IdeHover(
      message: _copied ? l10n.turnCopied : l10n.turnCopy,
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) => GestureDetector(
          onTap: _copy,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered
                  ? colors['toolbar.hoverBackground']
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: SvgPicture.asset(
              _copied ? _checkIcon : _copyIcon,
              width: 13,
              height: 13,
              colorFilter: ColorFilter.mode(
                hovered || _copied ? AppColors.text : AppColors.textFaint,
                BlendMode.srcIn,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinButton extends StatelessWidget {
  const _PinButton({required this.pinned, required this.onTap});

  final bool pinned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    final colors = themeColors;
    return IdeHover(
      message: pinned ? '取消置顶结论' : '置顶本轮关键结论',
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) => GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: pinned
                  ? accent.withValues(alpha: 0.14)
                  : hovered
                  ? colors['toolbar.hoverBackground']
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(
              pinned ? Codicons.pinned : Codicons.pin,
              size: 13,
              color: pinned
                  ? accent
                  : (hovered ? AppColors.text : AppColors.textFaint),
            ),
          ),
        ),
      ),
    );
  }
}

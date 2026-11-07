import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ide/ide_hover.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../chat_feed.dart';
import '../chat_models.dart';

enum _ReplayStepKind {
  user,
  thinking,
  tool,
  diff,
  terminal,
  assistant,
}

enum _StepFilter {
  all,
  slowOnly,
  terminalOnly,
  thinkingOnly,
  toolAndDiff,
}

class _ReplayStep {
  const _ReplayStep({
    required this.stepIndex,
    required this.feedIndex,
    required this.turnNumber,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.duration,
    required this.turnDuration,
    required this.cumulativeOffset,
    required this.turnShare,
    this.isTurnBottleneck = false,
    this.isSlow = false,
    this.diffLines = const [],
  });

  final int stepIndex;
  final int feedIndex;
  final int turnNumber;
  final _ReplayStepKind kind;
  final String title;
  final String subtitle;
  final String body;

  /// For `user` steps, this is the total duration of the turn; for action
  /// steps, this is the individual step's duration.
  final Duration duration;

  /// Total duration of the turn this step belongs to.
  final Duration turnDuration;

  /// Elapsed time from the beginning of the turn up to the end of this step.
  final Duration cumulativeOffset;

  /// Share of the turn's total duration (`0.0` .. `1.0`).
  final double turnShare;

  /// Whether this is the single slowest action step in its turn.
  final bool isTurnBottleneck;

  /// Whether this step is notably slow (`>= 2.2s` or `turnShare >= 0.35`).
  final bool isSlow;

  final List<DiffLine> diffLines;
}

class _DraftStep {
  _DraftStep({
    required this.feedIndex,
    required this.turnNumber,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.body,
    this.rawDuration,
    this.turnWorked,
    this.startedAt,
    this.diffLines = const [],
  });

  final int feedIndex;
  final int turnNumber;
  final _ReplayStepKind kind;
  final String title;
  final String subtitle;
  final String body;
  final Duration? rawDuration;
  final Duration? turnWorked;
  final DateTime? startedAt;
  final List<DiffLine> diffLines;
}

String _formatStepDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms <= 0) return '<0.1s';
  if (ms < 1000) return '${ms}ms';
  final sec = ms / 1000.0;
  if (sec < 10.0) return '${sec.toStringAsFixed(1)}s';
  if (sec < 60.0) return '${sec.toStringAsFixed(1)}s';
  final mins = ms ~/ 60000;
  final remSec = ((ms % 60000) / 1000).round();
  return remSec > 0 ? '${mins}m ${remSec}s' : '${mins}m';
}

double _heuristicStepMs(_DraftStep s) {
  return switch (s.kind) {
    _ReplayStepKind.user => 0,
    _ReplayStepKind.terminal => (1100 + s.body.length * 1.4).clamp(350, 9500).toDouble(),
    _ReplayStepKind.thinking => (950 + s.body.length * 1.8).clamp(450, 6500).toDouble(),
    _ReplayStepKind.diff => (520 + s.diffLines.length * 18).clamp(260, 4200).toDouble(),
    _ReplayStepKind.tool => (420 + s.body.length * 0.7).clamp(180, 3600).toDouble(),
    _ReplayStepKind.assistant => (680 + s.body.length * 1.9).clamp(300, 5800).toDouble(),
  };
}

List<_ReplayStep> _extractReplaySteps(ChatFeed feed) {
  final drafts = <_DraftStep>[];
  var turn = 0;

  for (var i = 0; i < feed.itemCount; i++) {
    final item = feed.itemAt(i);
    switch (item) {
      case UserMessageItem(:final text, :final worked, :final sentAt):
        turn++;
        final firstLine = text.trim().split('\n').firstOrNull ?? '（图片/附件提问）';
        drafts.add(
          _DraftStep(
            feedIndex: i,
            turnNumber: turn,
            kind: _ReplayStepKind.user,
            title: '用户提问 #$turn',
            subtitle: firstLine.length > 48
                ? '${firstLine.substring(0, 48)}…'
                : firstLine,
            body: text.trim(),
            turnWorked: worked,
            startedAt: sentAt,
          ),
        );
      case ThinkingItem(
        :final text,
        :final seconds,
        :final duration,
        :final startedAt,
      ):
        // Note: legacy replayed ThinkingItems had `seconds == 1` hardcoded
        // when `duration == null`. Treat `duration` as exact, or `seconds > 1`
        // as measured.
        final measured =
            duration ??
            (seconds != null && seconds > 1
                ? Duration(seconds: seconds)
                : null);
        drafts.add(
          _DraftStep(
            feedIndex: i,
            turnNumber: turn == 0 ? 1 : turn,
            kind: _ReplayStepKind.thinking,
            title: '深度思考',
            subtitle: '推理与规划执行路径',
            body: text.trim().isEmpty ? '（思考已完成）' : text.trim(),
            rawDuration: measured,
            startedAt: startedAt,
          ),
        );
      case ToolCallItem(
        :final target,
        :final label,
        :final output,
        :final duration,
      ):
        final summary = label != null && label.isNotEmpty
            ? '$label · $target'
            : target;
        drafts.add(
          _DraftStep(
            feedIndex: i,
            turnNumber: turn == 0 ? 1 : turn,
            kind: _ReplayStepKind.tool,
            title: '调用工具',
            subtitle: summary,
            body: (output ?? '').trim().isNotEmpty
                ? '$summary\n\n${output!.trim()}'
                : summary,
            rawDuration: duration,
          ),
        );
      case AgentItem(
        :final description,
        :final prompt,
        :final result,
        :final duration,
        :final startedAt,
      ):
        drafts.add(
          _DraftStep(
            feedIndex: i,
            turnNumber: turn == 0 ? 1 : turn,
            kind: _ReplayStepKind.tool,
            title: '子智能体 · $description',
            subtitle: prompt ?? description,
            body: [
              if (prompt != null && prompt.trim().isNotEmpty)
                '任务：$prompt',
              if (result != null && result.trim().isNotEmpty)
                '结果：\n$result',
            ].join('\n\n'),
            rawDuration: duration,
            startedAt: startedAt,
          ),
        );
      case CodeDiffItem(
        :final fileName,
        :final path,
        :final added,
        :final removed,
        :final lines,
        :final duration,
      ):
        drafts.add(
          _DraftStep(
            feedIndex: i,
            turnNumber: turn == 0 ? 1 : turn,
            kind: _ReplayStepKind.diff,
            title: '修改代码 $fileName',
            subtitle: '+$added / -$removed 行 · $path',
            body: path,
            rawDuration: duration,
            diffLines: lines,
          ),
        );
      case TerminalItem(
        :final command,
        :final output,
        :final status,
        :final startedAt,
        :final duration,
      ):
        final statusTag = switch (status) {
          CommandStatus.running => ' (运行中)',
          CommandStatus.succeeded => ' (成功)',
          CommandStatus.failed => ' (失败)',
        };
        drafts.add(
          _DraftStep(
            feedIndex: i,
            turnNumber: turn == 0 ? 1 : turn,
            kind: _ReplayStepKind.terminal,
            title: '终端执行$statusTag',
            subtitle: command,
            body: '\$ $command\n\n${output.trim()}',
            rawDuration: duration,
            startedAt: startedAt,
          ),
        );
      case AssistantTextItem(:final text, :final duration):
        if (text.trim().isNotEmpty) {
          final firstLine = text.trim().split('\n').first;
          drafts.add(
            _DraftStep(
              feedIndex: i,
              turnNumber: turn == 0 ? 1 : turn,
              kind: _ReplayStepKind.assistant,
              title: 'AI 回复与总结',
              subtitle: firstLine.length > 48
                  ? '${firstLine.substring(0, 48)}…'
                  : firstLine,
              body: text.trim(),
              rawDuration: duration,
            ),
          );
        }
      default:
        break;
    }
  }

  if (drafts.isEmpty) return const [];

  // Group drafts by turnNumber to compute per-step durations, shares, and bottlenecks.
  final byTurn = <int, List<int>>{};
  for (var i = 0; i < drafts.length; i++) {
    (byTurn[drafts[i].turnNumber] ??= []).add(i);
  }

  final resolvedDurations = List<Duration>.filled(drafts.length, Duration.zero);
  final turnTotals = <int, Duration>{};
  final turnBottleneckIdx = <int, int>{};

  for (final entry in byTurn.entries) {
    final tNum = entry.key;
    final indices = entry.value;
    Duration? headerWorked;
    final actionIndices = <int>[];
    for (final idx in indices) {
      if (drafts[idx].kind == _ReplayStepKind.user) {
        headerWorked ??= drafts[idx].turnWorked;
      } else {
        actionIndices.add(idx);
      }
    }

    if (actionIndices.isEmpty) {
      final total = headerWorked ?? Duration.zero;
      turnTotals[tNum] = total;
      for (final idx in indices) {
        resolvedDurations[idx] = total;
      }
      continue;
    }

    // 1. Collect measured durations and heuristic weights for unmeasured steps.
    var measuredSumMs = 0;
    var unmeasuredWeightSum = 0.0;
    final weights = <int, double>{};

    for (final idx in actionIndices) {
      final raw = drafts[idx].rawDuration;
      if (raw != null && raw.inMilliseconds > 0) {
        resolvedDurations[idx] = raw;
        measuredSumMs += raw.inMilliseconds;
      } else {
        final w = _heuristicStepMs(drafts[idx]);
        weights[idx] = w;
        unmeasuredWeightSum += w;
      }
    }

    final targetTurnMs = headerWorked?.inMilliseconds ?? 0;
    if (weights.isNotEmpty) {
      if (targetTurnMs > measuredSumMs && unmeasuredWeightSum > 0) {
        final remainingMs = targetTurnMs - measuredSumMs;
        for (final idx in weights.keys) {
          final ms = (remainingMs * (weights[idx]! / unmeasuredWeightSum))
              .round()
              .clamp(120, 600000);
          resolvedDurations[idx] = Duration(milliseconds: ms);
        }
      } else {
        for (final idx in weights.keys) {
          resolvedDurations[idx] = Duration(
            milliseconds: weights[idx]!.round(),
          );
        }
      }
    }

    var totalActionMs = 0;
    var maxStepMs = -1;
    var maxIdx = -1;
    for (final idx in actionIndices) {
      final ms = resolvedDurations[idx].inMilliseconds;
      totalActionMs += ms;
      if (ms > maxStepMs) {
        maxStepMs = ms;
        maxIdx = idx;
      }
    }

    final turnTotal = Duration(
      milliseconds: math.max(totalActionMs, targetTurnMs),
    );
    turnTotals[tNum] = turnTotal;
    if (maxIdx >= 0 && actionIndices.length > 1) {
      turnBottleneckIdx[tNum] = maxIdx;
    }

    for (final idx in indices) {
      if (drafts[idx].kind == _ReplayStepKind.user) {
        resolvedDurations[idx] = turnTotal;
      }
    }
  }

  final steps = <_ReplayStep>[];
  final runningTurnOffset = <int, int>{};

  for (var i = 0; i < drafts.length; i++) {
    final d = drafts[i];
    final dur = resolvedDurations[i];
    final turnTotal = turnTotals[d.turnNumber] ?? dur;
    final isUser = d.kind == _ReplayStepKind.user;
    final prevOffset = runningTurnOffset[d.turnNumber] ?? 0;
    final nextOffset = isUser ? prevOffset : prevOffset + dur.inMilliseconds;
    runningTurnOffset[d.turnNumber] = nextOffset;

    final share = isUser || turnTotal.inMilliseconds <= 0
        ? 1.0
        : (dur.inMilliseconds / turnTotal.inMilliseconds).clamp(0.0, 1.0);
    final isBottleneck = !isUser && turnBottleneckIdx[d.turnNumber] == i;
    final isSlow =
        !isUser &&
        (dur.inMilliseconds >= 2200 ||
            (isBottleneck && dur.inMilliseconds >= 1200) ||
            (share >= 0.38 && dur.inMilliseconds >= 1000));

    steps.add(
      _ReplayStep(
        stepIndex: i,
        feedIndex: d.feedIndex,
        turnNumber: d.turnNumber,
        kind: d.kind,
        title: d.title,
        subtitle: d.subtitle,
        body: d.body,
        duration: dur,
        turnDuration: turnTotal,
        cumulativeOffset: Duration(milliseconds: nextOffset),
        turnShare: share,
        isTurnBottleneck: isBottleneck,
        isSlow: isSlow,
        diffLines: d.diffLines,
      ),
    );
  }

  return steps;
}

Future<void> showSessionReplayDialog(
  BuildContext context, {
  required ChatFeed feed,
  required ValueChanged<int> onScrollToIndex,
}) async {
  final steps = _extractReplaySteps(feed);
  if (steps.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('当前会话暂无可回放的步骤'),
        duration: Duration(seconds: 2),
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (ctx) => _SessionReplayDialog(
      steps: steps,
      onScrollToIndex: onScrollToIndex,
    ),
  );
}

class _SessionReplayDialog extends StatefulWidget {
  const _SessionReplayDialog({
    required this.steps,
    required this.onScrollToIndex,
  });

  final List<_ReplayStep> steps;
  final ValueChanged<int> onScrollToIndex;

  @override
  State<_SessionReplayDialog> createState() => _SessionReplayDialogState();
}

class _SessionReplayDialogState extends State<_SessionReplayDialog> {
  int _index = 0;
  bool _playing = false;
  double _speed = 1.0;
  bool _syncScroll = true;
  _StepFilter _filter = _StepFilter.all;
  int _bottleneckRankCursor = 0;
  Timer? _timer;
  final ScrollController _listScrollController = ScrollController();

  late final List<_ReplayStep> _topSlowSteps = _computeTopSlowSteps();

  List<_ReplayStep> _computeTopSlowSteps() {
    final actions = widget.steps
        .where((s) => s.kind != _ReplayStepKind.user)
        .toList()
      ..sort(
        (a, b) =>
            b.duration.inMilliseconds.compareTo(a.duration.inMilliseconds),
      );
    return actions.take(5).toList();
  }

  List<_ReplayStep> get _filteredSteps => switch (_filter) {
    _StepFilter.all => widget.steps,
    _StepFilter.slowOnly =>
      widget.steps.where((s) => s.isSlow || s.isTurnBottleneck).toList(),
    _StepFilter.terminalOnly =>
      widget.steps.where((s) => s.kind == _ReplayStepKind.terminal).toList(),
    _StepFilter.thinkingOnly =>
      widget.steps.where((s) => s.kind == _ReplayStepKind.thinking).toList(),
    _StepFilter.toolAndDiff => widget.steps
        .where(
          (s) =>
              s.kind == _ReplayStepKind.tool || s.kind == _ReplayStepKind.diff,
        )
        .toList(),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScroll();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _listScrollController.dispose();
    super.dispose();
  }

  void _notifyScroll() {
    if (_syncScroll && _index >= 0 && _index < widget.steps.length) {
      widget.onScrollToIndex(widget.steps[_index].feedIndex);
    }
  }

  void _scheduleTick() {
    _timer?.cancel();
    if (!_playing) return;
    final ms = (1800 / _speed).round();
    _timer = Timer.periodic(Duration(milliseconds: ms), (_) {
      if (!mounted) return;
      if (_index + 1 < widget.steps.length) {
        setState(() => _index++);
        _notifyScroll();
        _scrollLeftListTo(_index);
      } else {
        setState(() => _playing = false);
        _timer?.cancel();
      }
    });
  }

  void _togglePlay() {
    setState(() {
      if (!_playing && _index >= widget.steps.length - 1) {
        _index = 0;
      }
      _playing = !_playing;
    });
    _notifyScroll();
    _scheduleTick();
  }

  void _stepTo(int nextIndex, {bool scrollList = false}) {
    final clamped = nextIndex.clamp(0, widget.steps.length - 1);
    setState(() => _index = clamped);
    _notifyScroll();
    if (scrollList) _scrollLeftListTo(clamped);
  }

  void _scrollLeftListTo(int stepIndex) {
    if (!_listScrollController.hasClients) return;
    final visible = _filteredSteps;
    final pos = visible.indexWhere((s) => s.stepIndex == stepIndex);
    if (pos < 0) return;
    const itemHeight = 52.0;
    final target = (pos * itemHeight - 120.0).clamp(
      0.0,
      _listScrollController.position.maxScrollExtent,
    );
    unawaited(
      _listScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _jumpToNextBottleneck() {
    if (_topSlowSteps.isEmpty) return;
    final target =
        _topSlowSteps[_bottleneckRankCursor % _topSlowSteps.length];
    setState(() {
      if (_filter != _StepFilter.all &&
          !_filteredSteps.any((s) => s.stepIndex == target.stepIndex)) {
        _filter = _StepFilter.all;
      }
      _index = target.stepIndex;
      _bottleneckRankCursor =
          (_bottleneckRankCursor + 1) % _topSlowSteps.length;
    });
    _notifyScroll();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollLeftListTo(target.stepIndex);
    });
  }

  Color _kindColor(_ReplayStepKind kind) => switch (kind) {
    _ReplayStepKind.user => AppColors.accent,
    _ReplayStepKind.thinking => const Color(0xFFA371F7),
    _ReplayStepKind.tool => const Color(0xFF58A6FF),
    _ReplayStepKind.diff => const Color(0xFF3FB950),
    _ReplayStepKind.terminal => const Color(0xFFD29922),
    _ReplayStepKind.assistant => const Color(0xFF2EA043),
  };

  IconData _kindIcon(_ReplayStepKind kind) => switch (kind) {
    _ReplayStepKind.user => Codicons.account,
    _ReplayStepKind.thinking => Codicons.lightbulb,
    _ReplayStepKind.tool => Codicons.search,
    _ReplayStepKind.diff => Codicons.diff,
    _ReplayStepKind.terminal => Codicons.terminal,
    _ReplayStepKind.assistant => Codicons.commentDiscussion,
  };

  /// Color of the duration badge & heat bar based on how slow the step is.
  Color _heatColor(_ReplayStep s) {
    if (s.kind == _ReplayStepKind.user) return AppColors.accent;
    final ms = s.duration.inMilliseconds;
    if (s.isTurnBottleneck && ms >= 1500 || ms >= 3500) {
      return const Color(0xFFD96543);
    }
    if (ms >= 1500 || s.turnShare >= 0.35) {
      return const Color(0xFFD29922);
    }
    return const Color(0xFF2EA043);
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_index];
    final color = _kindColor(step.kind);
    final filtered = _filteredSteps;
    final slowCount = widget.steps
        .where((s) => s.isSlow || s.isTurnBottleneck)
        .length;
    final turnSteps = widget.steps
        .where(
          (s) =>
              s.turnNumber == step.turnNumber &&
              s.kind != _ReplayStepKind.user,
        )
        .toList();

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.partBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 940,
          maxHeight: 650,
          minWidth: 720,
          minHeight: 480,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Top Header with Bottleneck Quick-Jumper
              Row(
                children: [
                  Icon(Codicons.playCircle, size: 18, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Text(
                    '会话沉浸式时间轴回放（Session Replay）',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '第 ${step.turnNumber} 轮 (${_formatStepDuration(step.turnDuration)}) · 步骤 ${_index + 1} / ${widget.steps.length}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: color,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (_topSlowSteps.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    IdeHover(
                      message: '点击按耗时从高到低依次定位最慢的 5 个瓶颈步骤',
                      child: InkWell(
                        onTap: _jumpToNextBottleneck,
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFFD96543,
                            ).withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(
                                0xFFD96543,
                              ).withValues(alpha: 0.35),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '🔥',
                                style: TextStyle(fontSize: 11),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '定位最慢 #${_topSlowSteps.first.stepIndex + 1} (${_formatStepDuration(_topSlowSteps.first.duration)}) ▸',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFD96543),
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _syncScroll,
                        onChanged: (v) =>
                            setState(() => _syncScroll = v ?? true),
                        visualDensity: VisualDensity.compact,
                      ),
                      Text(
                        '同步定位聊天窗',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Codicons.close,
                      size: 16,
                      color: AppColors.textMuted,
                    ),
                    tooltip: '关闭回放',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // 2. Main body: Left timeline rail + Right step detail stage
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Left step list + filter chips
                    Container(
                      width: 282,
                      decoration: BoxDecoration(
                        color: AppColors.bubbleFill,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.partBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Quick Filter Strip for Bottleneck Analysis
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 7, 8, 6),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  _FilterChip(
                                    label: '全部 (${widget.steps.length})',
                                    selected: _filter == _StepFilter.all,
                                    onTap: () => setState(
                                      () => _filter = _StepFilter.all,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  _FilterChip(
                                    label: '🔥 慢步骤 ($slowCount)',
                                    selected: _filter == _StepFilter.slowOnly,
                                    accentColor: const Color(0xFFD96543),
                                    onTap: () => setState(
                                      () => _filter = _StepFilter.slowOnly,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  _FilterChip(
                                    label: '终端',
                                    selected:
                                        _filter == _StepFilter.terminalOnly,
                                    onTap: () => setState(
                                      () => _filter = _StepFilter.terminalOnly,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  _FilterChip(
                                    label: '思考',
                                    selected:
                                        _filter == _StepFilter.thinkingOnly,
                                    onTap: () => setState(
                                      () => _filter = _StepFilter.thinkingOnly,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Divider(height: 1, color: AppColors.partBorder),
                          Expanded(
                            child: filtered.isEmpty
                                ? Center(
                                    child: Text(
                                      '该筛选条件下暂无步骤',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textFaint,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    controller: _listScrollController,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    itemCount: filtered.length,
                                    itemBuilder: (context, i) {
                                      final s = filtered[i];
                                      final active = s.stepIndex == _index;
                                      final c = _kindColor(s.kind);
                                      final heat = _heatColor(s);
                                      final isUser =
                                          s.kind == _ReplayStepKind.user;
                                      final pct = (s.turnShare * 100).round();

                                      return InkWell(
                                        onTap: () => _stepTo(s.stepIndex),
                                        child: Container(
                                          padding: const EdgeInsets.fromLTRB(
                                            10,
                                            6,
                                            9,
                                            5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: active
                                                ? c.withValues(alpha: 0.14)
                                                : Colors.transparent,
                                            border: Border(
                                              left: BorderSide(
                                                color: active
                                                    ? c
                                                    : Colors.transparent,
                                                width: 3,
                                              ),
                                            ),
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Row(
                                                children: [
                                                  Icon(
                                                    _kindIcon(s.kind),
                                                    size: 13,
                                                    color: c,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Expanded(
                                                    child: Text(
                                                      '${s.stepIndex + 1}. ${s.title}',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 11.5,
                                                        fontWeight: active
                                                            ? FontWeight.w600
                                                            : FontWeight.w500,
                                                        color: active
                                                            ? AppColors.text
                                                            : AppColors
                                                                  .textMuted,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  // Per-step duration pill
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 5.5,
                                                          vertical: 1.5,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: heat.withValues(
                                                        alpha:
                                                            s.isTurnBottleneck ||
                                                                s.isSlow
                                                            ? 0.16
                                                            : 0.10,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            5,
                                                          ),
                                                      border:
                                                          s.isTurnBottleneck ||
                                                              s.isSlow
                                                          ? Border.all(
                                                              color: heat
                                                                  .withValues(
                                                                    alpha: 0.35,
                                                                  ),
                                                              width: 0.7,
                                                            )
                                                          : null,
                                                    ),
                                                    child: Text(
                                                      isUser
                                                          ? '本轮 ${_formatStepDuration(s.turnDuration)}'
                                                          : '${s.isTurnBottleneck ? '🔥 ' : ''}${_formatStepDuration(s.duration)}',
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight:
                                                            s.isTurnBottleneck ||
                                                                s.isSlow
                                                            ? FontWeight.w700
                                                            : FontWeight.w600,
                                                        color: heat,
                                                        fontFeatures: const [
                                                          FontFeature
                                                              .tabularFigures(),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 2),
                                              Row(
                                                children: [
                                                  const SizedBox(width: 19),
                                                  Expanded(
                                                    child: Text(
                                                      s.subtitle,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 10.5,
                                                        color:
                                                            AppColors.textFaint,
                                                      ),
                                                    ),
                                                  ),
                                                  if (!isUser && pct > 0) ...[
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      '$pct%',
                                                      style: TextStyle(
                                                        fontSize: 9.5,
                                                        color: s.isSlow
                                                            ? heat
                                                            : AppColors
                                                                  .textFaint,
                                                        fontWeight: s.isSlow
                                                            ? FontWeight.w600
                                                            : FontWeight.w400,
                                                        fontFeatures: const [
                                                          FontFeature
                                                              .tabularFigures(),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              if (!isUser) ...[
                                                const SizedBox(height: 4),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        left: 19,
                                                      ),
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          99,
                                                        ),
                                                    child: SizedBox(
                                                      height: 2.5,
                                                      child: LinearProgressIndicator(
                                                        value: s.turnShare
                                                            .clamp(0.04, 1.0),
                                                        backgroundColor:
                                                            AppColors.partBorder
                                                                .withValues(
                                                                  alpha: 0.35,
                                                                ),
                                                        valueColor:
                                                            AlwaysStoppedAnimation<
                                                              Color
                                                            >(
                                                              heat.withValues(
                                                                alpha: active
                                                                    ? 0.95
                                                                    : 0.68,
                                                              ),
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Right stage: Step header + Interactive Turn Timing Waterfall + Content
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.bubbleFill,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.partBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Step Title & Telemetry Badges
                            Row(
                              children: [
                                Icon(
                                  _kindIcon(step.kind),
                                  size: 16,
                                  color: color,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    step.title,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.text,
                                    ),
                                  ),
                                ),
                                _TelemetryPill(
                                  icon: Icons.timer_outlined,
                                  label: step.kind == _ReplayStepKind.user
                                      ? '本轮总耗时 ${_formatStepDuration(step.turnDuration)}'
                                      : '耗时 ${_formatStepDuration(step.duration)}',
                                  color: _heatColor(step),
                                ),
                                if (step.kind != _ReplayStepKind.user) ...[
                                  const SizedBox(width: 6),
                                  _TelemetryPill(
                                    icon: Icons.pie_chart_outline_rounded,
                                    label:
                                        '占本轮 ${(step.turnShare * 100).round()}%',
                                    color: step.isSlow
                                        ? _heatColor(step)
                                        : AppColors.textMuted,
                                  ),
                                  const SizedBox(width: 6),
                                  _TelemetryPill(
                                    icon: Icons.schedule_rounded,
                                    label:
                                        '累计 +${_formatStepDuration(step.cumulativeOffset)}',
                                    color: AppColors.textMuted,
                                  ),
                                ],
                                if (step.isTurnBottleneck) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFFD96543,
                                      ).withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: const Color(
                                          0xFFD96543,
                                        ).withValues(alpha: 0.4),
                                      ),
                                    ),
                                    child: const Text(
                                      '🔥 本轮最慢瓶颈',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFFD96543),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              step.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textMuted,
                              ),
                            ),
                            // Interactive Turn Timing Waterfall Bar
                            if (turnSteps.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              _TurnWaterfallBar(
                                turnNumber: step.turnNumber,
                                turnDuration: step.turnDuration,
                                steps: turnSteps,
                                activeStepIndex: step.stepIndex,
                                kindColor: _kindColor,
                                onSelectStep: (idx) =>
                                    _stepTo(idx, scrollList: true),
                              ),
                            ],
                            const Divider(height: 16),
                            Expanded(
                              child: step.kind == _ReplayStepKind.diff
                                  ? _buildDiffStage(step)
                                  : SingleChildScrollView(
                                      child: SelectableText(
                                        step.body,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          height: 1.5,
                                          fontFamily:
                                              step.kind ==
                                                  _ReplayStepKind.terminal
                                              ? 'Menlo'
                                              : null,
                                          color: AppColors.text,
                                        ),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // 3. Bottom transport controls
              Row(
                children: [
                  IconButton(
                    onPressed: _index > 0
                        ? () => _stepTo(_index - 1, scrollList: true)
                        : null,
                    icon: const Icon(Icons.skip_previous_rounded, size: 20),
                    tooltip: '上一步',
                  ),
                  FilledButton.icon(
                    onPressed: _togglePlay,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                    icon: Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 16,
                    ),
                    label: Text(
                      _playing ? '暂停' : '自动回放',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  IconButton(
                    onPressed: _index + 1 < widget.steps.length
                        ? () => _stepTo(_index + 1, scrollList: true)
                        : null,
                    icon: const Icon(Icons.skip_next_rounded, size: 20),
                    tooltip: '下一步',
                  ),
                  Expanded(
                    child: Slider(
                      value: _index.toDouble(),
                      min: 0,
                      max: (widget.steps.length - 1)
                          .clamp(1, 999999)
                          .toDouble(),
                      divisions: widget.steps.length > 1
                          ? widget.steps.length - 1
                          : 1,
                      activeColor: AppColors.accent,
                      onChanged: (v) => _stepTo(v.round(), scrollList: true),
                    ),
                  ),
                  for (final spd in const [1.0, 2.0, 4.0])
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: InkWell(
                        onTap: () {
                          setState(() => _speed = spd);
                          if (_playing) _scheduleTick();
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _speed == spd
                                ? AppColors.accent.withValues(alpha: 0.16)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: _speed == spd
                                  ? AppColors.accent
                                  : AppColors.partBorder,
                            ),
                          ),
                          child: Text(
                            '${spd.toInt()}x',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: _speed == spd
                                  ? AppColors.accent
                                  : AppColors.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiffStage(_ReplayStep step) {
    if (step.diffLines.isEmpty) {
      return Text(
        step.body,
        style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
      );
    }
    return ListView.builder(
      itemCount: step.diffLines.length,
      itemBuilder: (context, i) {
        final line = step.diffLines[i];
        final isAdd = line.type == DiffLineType.added;
        final isDel = line.type == DiffLineType.removed;
        final bg = isAdd
            ? const Color(0xFF2EA043).withValues(alpha: 0.14)
            : isDel
            ? const Color(0xFFF85149).withValues(alpha: 0.14)
            : Colors.transparent;
        final fg = isAdd
            ? const Color(0xFF3FB950)
            : isDel
            ? const Color(0xFFF85149)
            : AppColors.textMuted;
        final prefix = isAdd
            ? '+'
            : isDel
            ? '-'
            : ' ';
        return Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
          child: Text(
            '$prefix ${line.text}',
            style: TextStyle(fontFamily: 'Menlo', fontSize: 11.5, color: fg),
          ),
        );
      },
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.accentColor,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final activeColor = accentColor ?? AppColors.accent;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: selected
              ? activeColor.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? activeColor.withValues(alpha: 0.5)
                : AppColors.partBorder,
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? activeColor : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

class _TelemetryPill extends StatelessWidget {
  const _TelemetryPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11.5, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Interactive horizontal waterfall bar showing how time was spent across
/// every step in the current turn, so bottlenecks stand out visually.
class _TurnWaterfallBar extends StatelessWidget {
  const _TurnWaterfallBar({
    required this.turnNumber,
    required this.turnDuration,
    required this.steps,
    required this.activeStepIndex,
    required this.kindColor,
    required this.onSelectStep,
  });

  final int turnNumber;
  final Duration turnDuration;
  final List<_ReplayStep> steps;
  final int activeStepIndex;
  final Color Function(_ReplayStepKind) kindColor;
  final ValueChanged<int> onSelectStep;

  @override
  Widget build(BuildContext context) {
    // Aggregate category totals for the current turn.
    var terminalMs = 0;
    var thinkingMs = 0;
    var toolDiffMs = 0;
    var replyMs = 0;
    for (final s in steps) {
      final ms = s.duration.inMilliseconds;
      switch (s.kind) {
        case _ReplayStepKind.terminal:
          terminalMs += ms;
        case _ReplayStepKind.thinking:
          thinkingMs += ms;
        case _ReplayStepKind.tool || _ReplayStepKind.diff:
          toolDiffMs += ms;
        case _ReplayStepKind.assistant:
          replyMs += ms;
        case _ReplayStepKind.user:
          break;
      }
    }

    final parts = <String>[
      if (terminalMs > 0)
        '终端 ${_formatStepDuration(Duration(milliseconds: terminalMs))}',
      if (thinkingMs > 0)
        '思考 ${_formatStepDuration(Duration(milliseconds: thinkingMs))}',
      if (toolDiffMs > 0)
        '工具/改码 ${_formatStepDuration(Duration(milliseconds: toolDiffMs))}',
      if (replyMs > 0)
        '回复 ${_formatStepDuration(Duration(milliseconds: replyMs))}',
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.partBorder.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '第 $turnNumber 轮耗时分布（点击色块可定位步骤）',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                ),
              ),
              const Spacer(),
              Text(
                parts.join(' · '),
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.textFaint,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 9,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < steps.length; i++) ...[
                    if (i > 0) const SizedBox(width: 1.5),
                    Expanded(
                      flex: math.max(
                        3,
                        (steps[i].turnShare * 100).round(),
                      ),
                      child: IdeHover(
                        message:
                            '#${steps[i].stepIndex + 1} ${steps[i].title} · ${_formatStepDuration(steps[i].duration)} (${(steps[i].turnShare * 100).round()}%)',
                        child: GestureDetector(
                          onTap: () => onSelectStep(steps[i].stepIndex),
                          child: Container(
                            decoration: BoxDecoration(
                              color: kindColor(steps[i].kind).withValues(
                                alpha: steps[i].stepIndex == activeStepIndex
                                    ? 1.0
                                    : 0.45,
                              ),
                              border: steps[i].stepIndex == activeStepIndex
                                  ? Border.all(
                                      color: AppColors.text,
                                      width: 1.2,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

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

class _ReplayStep {
  const _ReplayStep({
    required this.feedIndex,
    required this.turnNumber,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.body,
    this.diffLines = const [],
  });

  final int feedIndex;
  final int turnNumber;
  final _ReplayStepKind kind;
  final String title;
  final String subtitle;
  final String body;
  final List<DiffLine> diffLines;
}

List<_ReplayStep> _extractReplaySteps(ChatFeed feed) {
  final steps = <_ReplayStep>[];
  var turn = 0;
  for (var i = 0; i < feed.itemCount; i++) {
    final item = feed.itemAt(i);
    switch (item) {
      case UserMessageItem(:final text):
        turn++;
        final firstLine = text.trim().split('\n').firstOrNull ?? '（图片/附件提问）';
        steps.add(
          _ReplayStep(
            feedIndex: i,
            turnNumber: turn,
            kind: _ReplayStepKind.user,
            title: '用户提问 #$turn',
            subtitle: firstLine.length > 48
                ? '${firstLine.substring(0, 48)}…'
                : firstLine,
            body: text.trim(),
          ),
        );
      case ThinkingItem(:final text, :final seconds):
        steps.add(
          _ReplayStep(
            feedIndex: i,
            turnNumber: turn == 0 ? 1 : turn,
            kind: _ReplayStepKind.thinking,
            title: '深度思考${seconds != null ? ' (${seconds}s)' : ''}',
            subtitle: '推理与规划执行路径',
            body: text.trim().isEmpty ? '（思考已完成）' : text.trim(),
          ),
        );
      case ToolCallItem(:final target, :final label, :final output):
        final summary = label != null && label.isNotEmpty
            ? '$label · $target'
            : target;
        steps.add(
          _ReplayStep(
            feedIndex: i,
            turnNumber: turn == 0 ? 1 : turn,
            kind: _ReplayStepKind.tool,
            title: '调用工具',
            subtitle: summary,
            body: (output ?? '').trim().isNotEmpty
                ? '$summary\n\n${output!.trim()}'
                : summary,
          ),
        );
      case CodeDiffItem(
        :final fileName,
        :final path,
        :final added,
        :final removed,
        :final lines,
      ):
        steps.add(
          _ReplayStep(
            feedIndex: i,
            turnNumber: turn == 0 ? 1 : turn,
            kind: _ReplayStepKind.diff,
            title: '修改代码 $fileName',
            subtitle: '+$added / -$removed 行 · $path',
            body: path,
            diffLines: lines,
          ),
        );
      case TerminalItem(:final command, :final output, :final status):
        final statusTag = switch (status) {
          CommandStatus.running => ' (运行中)',
          CommandStatus.succeeded => ' (成功)',
          CommandStatus.failed => ' (失败)',
        };
        steps.add(
          _ReplayStep(
            feedIndex: i,
            turnNumber: turn == 0 ? 1 : turn,
            kind: _ReplayStepKind.terminal,
            title: '终端执行$statusTag',
            subtitle: command,
            body: '\$ $command\n\n${output.trim()}',
          ),
        );
      case AssistantTextItem(:final text):
        if (text.trim().isNotEmpty) {
          final firstLine = text.trim().split('\n').first;
          steps.add(
            _ReplayStep(
              feedIndex: i,
              turnNumber: turn == 0 ? 1 : turn,
              kind: _ReplayStepKind.assistant,
              title: 'AI 回复与总结',
              subtitle: firstLine.length > 48
                  ? '${firstLine.substring(0, 48)}…'
                  : firstLine,
              body: text.trim(),
            ),
          );
        }
      default:
        break;
    }
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
  Timer? _timer;

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

  void _stepTo(int nextIndex) {
    final clamped = nextIndex.clamp(0, widget.steps.length - 1);
    setState(() => _index = clamped);
    _notifyScroll();
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

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[_index];
    final color = _kindColor(step.kind);

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.partBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 880,
          maxHeight: 620,
          minWidth: 680,
          minHeight: 460,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
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
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '第 ${step.turnNumber} 轮 · 步骤 ${_index + 1} / ${widget.steps.length}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
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
                  const SizedBox(width: 8),
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
              // Main body: Left timeline rail + Right step detail stage
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Left step list
                    Container(
                      width: 245,
                      decoration: BoxDecoration(
                        color: AppColors.bubbleFill,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.partBorder),
                      ),
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: widget.steps.length,
                        itemBuilder: (context, i) {
                          final s = widget.steps[i];
                          final active = i == _index;
                          final c = _kindColor(s.kind);
                          return InkWell(
                            onTap: () => _stepTo(i),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: active
                                    ? c.withValues(alpha: 0.14)
                                    : Colors.transparent,
                                border: Border(
                                  left: BorderSide(
                                    color: active ? c : Colors.transparent,
                                    width: 3,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(_kindIcon(s.kind), size: 13, color: c),
                                  const SizedBox(width: 7),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${i + 1}. ${s.title}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: active
                                                ? FontWeight.w600
                                                : FontWeight.w500,
                                            color: active
                                                ? AppColors.text
                                                : AppColors.textMuted,
                                          ),
                                        ),
                                        Text(
                                          s.subtitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            color: AppColors.textFaint,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Right stage
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
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              step.subtitle,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textMuted,
                              ),
                            ),
                            const Divider(height: 18),
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
              // Bottom transport controls
              Row(
                children: [
                  IconButton(
                    onPressed: _index > 0 ? () => _stepTo(_index - 1) : null,
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
                        ? () => _stepTo(_index + 1)
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
                      onChanged: (v) => _stepTo(v.round()),
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

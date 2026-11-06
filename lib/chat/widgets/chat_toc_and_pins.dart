import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ide/ide_hover.dart';
import '../../ide/ide_notifications.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../chat_feed.dart';
import '../chat_models.dart';
import 'hover_builder.dart';
import 'session_replay_player.dart';
import 'turn_power_tools.dart';

class PinnedConclusion {
  const PinnedConclusion({
    required this.turnIndex,
    required this.promptTitle,
    required this.answer,
    required this.pinnedAt,
  });

  final int turnIndex;
  final String promptTitle;
  final String answer;
  final DateTime pinnedAt;
}

/// Manages pinned assistant conclusions per conversation feed/session.
class ChatPinsStore extends ChangeNotifier {
  ChatPinsStore._();

  static final ChatPinsStore instance = ChatPinsStore._();

  final Expando<List<PinnedConclusion>> _byFeed = Expando('chatPins');

  List<PinnedConclusion> pinsFor(ChatFeed feed) =>
      List.unmodifiable(_byFeed[feed] ?? const []);

  bool isPinned(ChatFeed feed, int turnIndex) {
    final list = _byFeed[feed];
    if (list == null) return false;
    return list.any((p) => p.turnIndex == turnIndex);
  }

  void togglePin(
    ChatFeed feed, {
    required int turnIndex,
    required String promptTitle,
    required String answer,
  }) {
    final list = _byFeed[feed] ??= <PinnedConclusion>[];
    final existing = list.indexWhere((p) => p.turnIndex == turnIndex);
    if (existing >= 0) {
      list.removeAt(existing);
    } else {
      list.add(
        PinnedConclusion(
          turnIndex: turnIndex,
          promptTitle: promptTitle.trim().isEmpty ? '结论摘要' : promptTitle.trim(),
          answer: answer.trim(),
          pinnedAt: DateTime.now(),
        ),
      );
      list.sort((a, b) => a.turnIndex.compareTo(b.turnIndex));
    }
    notifyListeners();
  }

  void removePin(ChatFeed feed, int turnIndex) {
    final list = _byFeed[feed];
    if (list == null) return;
    list.removeWhere((p) => p.turnIndex == turnIndex);
    notifyListeners();
  }
}

/// Collapsible bar shown below the chat header when a conversation has
/// pinned conclusions.
class PinnedConclusionsBar extends StatefulWidget {
  const PinnedConclusionsBar({
    super.key,
    required this.feed,
    required this.onJumpToTurn,
  });

  final ChatFeed feed;
  final ValueChanged<int> onJumpToTurn;

  @override
  State<PinnedConclusionsBar> createState() => _PinnedConclusionsBarState();
}

class _PinnedConclusionsBarState extends State<PinnedConclusionsBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ChatPinsStore.instance,
      builder: (context, _) {
        final pins = ChatPinsStore.instance.pinsFor(widget.feed);
        if (pins.isEmpty) return const SizedBox.shrink();
        final accent = AppColors.accent;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: accent.withValues(alpha: 0.3)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    HoverBuilder(
                      cursor: SystemMouseCursors.click,
                      builder: (context, hovered) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _expanded = !_expanded),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          child: Row(
                            children: [
                              Icon(Codicons.pinned, size: 13, color: accent),
                              const SizedBox(width: 6),
                              Text(
                                '已置顶关键结论 (${pins.length})',
                                style: TextStyle(
                                  color: AppColors.text,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (!_expanded)
                                Expanded(
                                  child: Text(
                                    pins.last.answer
                                        .replaceAll('\n', ' ')
                                        .trim(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                )
                              else
                                const Spacer(),
                              const SizedBox(width: 6),
                              Icon(
                                _expanded
                                    ? Codicons.chevronUp
                                    : Codicons.chevronDown,
                                size: 14,
                                color: AppColors.textMuted,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_expanded) ...[
                      Divider(height: 1, color: AppColors.partBorder),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 0; i < pins.length; i++) ...[
                                if (i > 0)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    child: Divider(
                                      height: 1,
                                      color: AppColors.partBorder,
                                    ),
                                  ),
                                _PinCardRow(
                                  pin: pins[i],
                                  onJump: () =>
                                      widget.onJumpToTurn(pins[i].turnIndex),
                                  onRemove: () => ChatPinsStore.instance
                                      .removePin(
                                        widget.feed,
                                        pins[i].turnIndex,
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PinCardRow extends StatelessWidget {
  const _PinCardRow({
    required this.pin,
    required this.onJump,
    required this.onRemove,
  });

  final PinnedConclusion pin;
  final VoidCallback onJump;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final preview = pin.answer.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onJump,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Q: ${pin.promptTitle.split('\n').first}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  preview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        IdeHover(
          message: '定位到原文',
          child: HoverBuilder(
            cursor: SystemMouseCursors.click,
            builder: (context, hovered) => GestureDetector(
              onTap: onJump,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Codicons.goToFile,
                  size: 13,
                  color: hovered ? AppColors.text : AppColors.textMuted,
                ),
              ),
            ),
          ),
        ),
        IdeHover(
          message: '🧠 记入项目记忆 (写入 CLAUDE.md)',
          child: HoverBuilder(
            cursor: SystemMouseCursors.click,
            builder: (context, hovered) => GestureDetector(
              onTap: () => unawaited(
                showMemoryCapsuleDialog(
                  context,
                  answer: pin.answer,
                  promptText: pin.promptTitle,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Codicons.book,
                  size: 13,
                  color: hovered ? AppColors.text : AppColors.textMuted,
                ),
              ),
            ),
          ),
        ),
        IdeHover(
          message: '复制结论',
          child: HoverBuilder(
            cursor: SystemMouseCursors.click,
            builder: (context, hovered) => GestureDetector(
              onTap: () =>
                  Clipboard.setData(ClipboardData(text: pin.answer)),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Codicons.copy,
                  size: 13,
                  color: hovered ? AppColors.text : AppColors.textMuted,
                ),
              ),
            ),
          ),
        ),
        IdeHover(
          message: '取消置顶',
          child: HoverBuilder(
            cursor: SystemMouseCursors.click,
            builder: (context, hovered) => GestureDetector(
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Codicons.close,
                  size: 13,
                  color: hovered ? AppColors.text : AppColors.textMuted,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Right-edge floating Mini-TOC (table of contents) tick rail for jumping
/// between user turns and pinned conclusions in a conversation.
class ChatMiniTocRail extends StatefulWidget {
  const ChatMiniTocRail({
    super.key,
    required this.feed,
    required this.onJumpToTurn,
  });

  final ChatFeed feed;
  final ValueChanged<int> onJumpToTurn;

  @override
  State<ChatMiniTocRail> createState() => _ChatMiniTocRailState();
}

class _ChatMiniTocRailState extends State<ChatMiniTocRail> {
  bool _hovered = false;

  List<({int index, int turnNumber, String title, bool pinned})> _collectTurns() {
    final feed = widget.feed;
    final turns = <({int index, int turnNumber, String title, bool pinned})>[];
    var turnNo = 0;
    for (var i = 0; i < feed.itemCount; i++) {
      if (feed.itemAt(i) case UserMessageItem(:final text, fromAgent: null)) {
        turnNo++;
        final firstLine = text.trim().split('\n').first;
        turns.add((
          index: i,
          turnNumber: turnNo,
          title: firstLine.isEmpty ? '提问 #$turnNo' : firstLine,
          pinned: ChatPinsStore.instance.isPinned(feed, i),
        ));
      }
    }
    return turns;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.feed, ChatPinsStore.instance]),
      builder: (context, _) {
        final turns = _collectTurns();
        if (turns.length < 2) return const SizedBox.shrink();
        final colors = themeColors;
        return MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            width: _hovered ? 228 : 18,
            constraints: const BoxConstraints(maxHeight: 340),
            padding: EdgeInsets.symmetric(
              horizontal: _hovered ? 8 : 3,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: _hovered
                  ? AppColors.surface.withValues(alpha: 0.96)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: _hovered
                  ? Border.all(color: AppColors.partBorder)
                  : null,
              boxShadow: _hovered
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.14),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: _hovered
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                        child: Row(
                          children: [
                            Icon(
                              Codicons.listSelection,
                              size: 12,
                              color: AppColors.textMuted,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '对话目录 (${turns.length})',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            IdeHover(
                              message: '🎞️ 沉浸式时间轴回放（Session Replay）',
                              child: HoverBuilder(
                                cursor: SystemMouseCursors.click,
                                builder: (context, repHover) => GestureDetector(
                                  onTap: () => unawaited(
                                    showSessionReplayDialog(
                                      context,
                                      feed: widget.feed,
                                      onScrollToIndex: widget.onJumpToTurn,
                                    ),
                                  ),
                                  child: Icon(
                                    Codicons.playCircle,
                                    size: 13,
                                    color: repHover
                                        ? AppColors.accent
                                        : AppColors.textMuted,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IdeHover(
                              message: '📤 导出完整会话 Markdown (.md)',
                              child: HoverBuilder(
                                cursor: SystemMouseCursors.click,
                                builder: (context, expHover) => GestureDetector(
                                  onTap: () async {
                                    final md = MarkdownExporter.formatFullSession(
                                      widget.feed,
                                    );
                                    await Clipboard.setData(
                                      ClipboardData(text: md),
                                    );
                                    final path =
                                        await MarkdownExporter.saveToDownloads(
                                          md,
                                          prefix: 'Kestrel-会话复盘',
                                        );
                                    if (!context.mounted) return;
                                    IdeNotificationsScope.maybeOf(
                                      context,
                                    )?.notify(
                                      IdeSeverity.info,
                                      path != null
                                          ? '📤 已复制并导出完整会话至：$path'
                                          : '📤 已复制完整会话 Markdown 笔记',
                                    );
                                  },
                                  child: Icon(
                                    Codicons.markdown,
                                    size: 13,
                                    color: expHover
                                        ? AppColors.text
                                        : AppColors.textMuted,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final turn in turns)
                                HoverBuilder(
                                  cursor: SystemMouseCursors.click,
                                  builder: (context, rowHovered) =>
                                      GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () =>
                                            widget.onJumpToTurn(turn.index),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: rowHovered
                                                ? colors['toolbar.hoverBackground']
                                                : Colors.transparent,
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Text(
                                                '#${turn.turnNumber}',
                                                style: TextStyle(
                                                  color: turn.pinned
                                                      ? AppColors.accent
                                                      : AppColors.textFaint,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text(
                                                  turn.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: AppColors.text,
                                                    fontSize: 11.5,
                                                  ),
                                                ),
                                              ),
                                              if (turn.pinned) ...[
                                                const SizedBox(width: 4),
                                                Icon(
                                                  Codicons.pinned,
                                                  size: 11,
                                                  color: AppColors.accent,
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final turn in turns.take(18))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2.5),
                          child: Container(
                            width: turn.pinned ? 10 : 7,
                            height: 2.5,
                            decoration: BoxDecoration(
                              color: turn.pinned
                                  ? AppColors.accent
                                  : AppColors.textFaint.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

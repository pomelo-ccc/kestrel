import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../ide/ide_hover.dart';
import '../../ide/ide_menu.dart';
import '../../ide/ide_notifications.dart';
import '../../ide/ide_spinning.dart';
import '../../kernel/claude_code/claude_haiku.dart';
import '../../models/model_provider.dart';
import '../../models/model_providers.dart';
import '../../models/provider_health.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../chat_feed.dart';
import '../chat_models.dart';
import '../chat_session.dart';
import '../side_panel/file_open.dart';
import 'agent_step.dart';
import 'chat_toc_and_pins.dart';
import 'hover_builder.dart';

/// Aggregated file edit & command execution metrics for a single turn.
class TurnSummaryData {
  const TurnSummaryData({
    required this.promptIndex,
    required this.endIndex,
    required this.promptText,
    required this.answerText,
    required this.worked,
    required this.usage,
    required this.editedFiles,
    required this.commandsRun,
    required this.commandsFailed,
    required this.toolSteps,
  });

  final int promptIndex;
  final int endIndex;
  final String promptText;
  final String? answerText;
  final Duration? worked;
  final TurnUsage? usage;
  final List<({String path, String fileName, int added, int removed})>
  editedFiles;
  final int commandsRun;
  final int commandsFailed;
  final int toolSteps;

  int get totalAdded =>
      editedFiles.fold(0, (sum, item) => sum + item.added);
  int get totalRemoved =>
      editedFiles.fold(0, (sum, item) => sum + item.removed);

  /// Whether this turn has enough activity to show the Turn Summary Card.
  bool get hasNotableActivity =>
      editedFiles.isNotEmpty ||
      commandsRun > 0 ||
      (worked != null && worked!.inSeconds >= 15);

  static TurnSummaryData collect(
    ChatFeed feed, {
    required int promptIndex,
    required int endIndex,
    required String? answerText,
  }) {
    final promptItem = feed.itemAt(promptIndex);
    final promptText = promptItem is UserMessageItem ? promptItem.text : '';
    final worked = promptItem is UserMessageItem ? promptItem.worked : null;
    final usage = promptItem is UserMessageItem ? promptItem.usage : null;

    final fileMap =
        <String, ({String path, String fileName, int added, int removed})>{};
    var commandsRun = 0;
    var commandsFailed = 0;
    var toolSteps = 0;

    for (var i = promptIndex + 1; i <= endIndex && i < feed.itemCount; i++) {
      final item = feed.itemAt(i);
      switch (item) {
        case CodeDiffItem(
          :final path,
          :final fileName,
          :final added,
          :final removed,
        ):
          final prev = fileMap[path];
          fileMap[path] = (
            path: path,
            fileName: fileName,
            added: (prev?.added ?? 0) + added,
            removed: (prev?.removed ?? 0) + removed,
          );
          toolSteps++;
        case TerminalItem(:final status):
          commandsRun++;
          if (status == CommandStatus.failed) commandsFailed++;
          toolSteps++;
        case ToolCallItem():
          toolSteps++;
        case AgentItem():
          toolSteps++;
        default:
          break;
      }
    }

    return TurnSummaryData(
      promptIndex: promptIndex,
      endIndex: endIndex,
      promptText: promptText,
      answerText: answerText,
      worked: worked,
      usage: usage,
      editedFiles: fileMap.values.toList(),
      commandsRun: commandsRun,
      commandsFailed: commandsFailed,
      toolSteps: toolSteps,
    );
  }
}

/// ⏱️ Compact summary card shown at the end of a turn that modified files,
/// executed commands, or ran for >= 15s.
class TurnSummaryCard extends StatelessWidget {
  const TurnSummaryCard({super.key, required this.summary});

  final TurnSummaryData summary;

  @override
  Widget build(BuildContext context) {
    if (!summary.hasNotableActivity) return const SizedBox.shrink();
    final accent = AppColors.accent;
    final files = summary.editedFiles;
    final worked = summary.worked;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.bubbleFill.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: AppColors.partBorder.withValues(alpha: 0.85),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Codicons.checkAll, size: 13, color: accent),
                    const SizedBox(width: 5),
                    Text(
                      '本轮执行摘要',
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                if (worked != null)
                  _BadgeChip(
                    icon: Codicons.watch,
                    text: '耗时 ${AgentStep.formatDuration(worked)}',
                  ),
                if (files.isNotEmpty)
                  _BadgeChip(
                    icon: Codicons.diff,
                    text:
                        '修改 ${files.length} 个文件 (+${summary.totalAdded} / -${summary.totalRemoved})',
                  ),
                if (summary.commandsRun > 0)
                  _BadgeChip(
                    icon: Codicons.terminal,
                    text: summary.commandsFailed > 0
                        ? '执行 ${summary.commandsRun} 条命令 (${summary.commandsFailed} 失败)'
                        : '执行 ${summary.commandsRun} 条命令',
                  ),
              ],
            ),
            if (files.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 5,
                children: [
                  for (final file in files) _EditedFilePill(file: file),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: AppColors.textMuted),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _EditedFilePill extends StatelessWidget {
  const _EditedFilePill({required this.file});

  final ({String path, String fileName, int added, int removed}) file;

  void _open(BuildContext context) {
    final scope = FileOpenScope.find(context);
    if (scope == null) return;
    final resolved = scope.resolve(file.path) ?? file.path;
    scope.onOpen(FileOpenRequest(resolved));
  }

  @override
  Widget build(BuildContext context) {
    return IdeHover(
      message: '点击打开 ${file.path}',
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) => GestureDetector(
          onTap: () => _open(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
            decoration: BoxDecoration(
              color: hovered ? AppColors.hover : AppColors.surface,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: AppColors.partBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Codicons.fileCode,
                  size: 11.5,
                  color: hovered ? AppColors.text : AppColors.textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  file.fileName,
                  style: TextStyle(
                    color: hovered ? AppColors.text : AppColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (file.added > 0) ...[
                  const SizedBox(width: 5),
                  Text(
                    '+${file.added}',
                    style: const TextStyle(
                      color: Color(0xFF2EA043),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (file.removed > 0) ...[
                  const SizedBox(width: 3),
                  Text(
                    '-${file.removed}',
                    style: const TextStyle(
                      color: Color(0xFFD1242F),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 🧠 Feature 3A: Project Memory Capsule (Write rule to CLAUDE.md)
// ---------------------------------------------------------------------------

class ProjectMemoryButton extends StatelessWidget {
  const ProjectMemoryButton({
    super.key,
    required this.answer,
    this.promptText,
    this.projectRoot,
  });

  final String answer;
  final String? promptText;
  final String? projectRoot;

  @override
  Widget build(BuildContext context) {
    return IdeHover(
      message: '🧠 记入项目记忆胶囊 (写入 CLAUDE.md 永久生效)',
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) => GestureDetector(
          onTap: () => unawaited(
            showMemoryCapsuleDialog(
              context,
              answer: answer,
              promptText: promptText,
              projectRoot:
                  projectRoot ?? FileOpenScope.find(context)?.root,
            ),
          ),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: hovered ? AppColors.hover : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              Codicons.book,
              size: 13,
              color: hovered ? AppColors.text : AppColors.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showMemoryCapsuleDialog(
  BuildContext context, {
  required String answer,
  String? promptText,
  String? projectRoot,
}) async {
  final root = projectRoot ?? FileOpenScope.find(context)?.root;
  final home = Platform.environment['HOME'] ?? '';
  final projectClaudeMd = root != null && root.isNotEmpty
      ? p.join(root, 'CLAUDE.md')
      : null;
  final globalClaudeMd = home.isNotEmpty
      ? p.join(home, '.claude', 'CLAUDE.md')
      : 'CLAUDE.md';

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _MemoryCapsuleDialog(
      initialText: _extractDefaultMemoryRule(answer),
      rawAnswer: answer,
      promptText: promptText,
      projectClaudeMd: projectClaudeMd,
      globalClaudeMd: globalClaudeMd,
      onSaved: (savedPath) {
        IdeNotificationsScope.maybeOf(context)?.notify(
          IdeSeverity.info,
          '🧠 已写入项目记忆：$savedPath',
        );
      },
    ),
  );
}

String _extractDefaultMemoryRule(String answer) {
  final trimmed = answer.trim();
  if (trimmed.length <= 360) return '- $trimmed';
  final lines = trimmed
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('```'))
      .take(5)
      .toList();
  return lines.map((l) => l.startsWith('-') ? l : '- $l').join('\n');
}

class _MemoryCapsuleDialog extends StatefulWidget {
  const _MemoryCapsuleDialog({
    required this.initialText,
    required this.rawAnswer,
    this.promptText,
    this.projectClaudeMd,
    required this.globalClaudeMd,
    required this.onSaved,
  });

  final String initialText;
  final String rawAnswer;
  final String? promptText;
  final String? projectClaudeMd;
  final String globalClaudeMd;
  final ValueChanged<String> onSaved;

  @override
  State<_MemoryCapsuleDialog> createState() => _MemoryCapsuleDialogState();
}

class _MemoryCapsuleDialogState extends State<_MemoryCapsuleDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );
  late bool _useGlobal = widget.projectClaudeMd == null;
  bool _distilling = false;

  String get _targetPath =>
      _useGlobal || widget.projectClaudeMd == null
          ? widget.globalClaudeMd
          : widget.projectClaudeMd!;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _distillWithAi() async {
    if (_distilling) return;
    setState(() => _distilling = true);
    try {
      const system =
          'You distill an AI coding assistant reply into 1 to 3 concise, '
          'reusable project memory rules for CLAUDE.md. Write in the same '
          'language as the reply (Chinese if Chinese). Output ONLY Markdown '
          'bullet points starting with "- ", with no preamble or fences.';
      final prompt = [
        if (widget.promptText != null && widget.promptText!.trim().isNotEmpty)
          'Context question: ${widget.promptText!.trim()}',
        'Reply to distill:\n${widget.rawAnswer}',
      ].join('\n\n');
      final models = ModelProviders.current;
      final candidates = <({String? model, bool exact})>[
        models.auxiliary(models.defaultModel),
        for (final provider in models.enabled)
          models.auxiliary(
            provider.models.isNotEmpty
                ? modelRef(provider.id, provider.models.first.id)
                : modelRef(provider.id, 'haiku'),
          ),
      ];
      final seen = <String?>{};
      for (final c in candidates) {
        if (!seen.add(c.model)) continue;
        try {
          final res = await askClaudeHaiku(
            system,
            prompt,
            model: c.model,
            exact: c.exact,
          );
          if (res.trim().isNotEmpty && mounted) {
            _controller.text = res.trim();
            break;
          }
        } on Object {
          // Try next provider.
        }
      }
    } finally {
      if (mounted) setState(() => _distilling = false);
    }
  }

  Future<void> _save() async {
    final rule = _controller.text.trim();
    if (rule.isEmpty) return;
    final path = _targetPath;
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      const sectionHeader = '## 🧠 Byte 项目记忆与规范';
      final dateStr = DateTime.now().toIso8601String().substring(0, 10);
      final entry = '\n<!-- $dateStr -->\n$rule\n';
      if (await file.exists()) {
        final existing = await file.readAsString();
        if (existing.contains(sectionHeader)) {
          await file.writeAsString('${existing.trimRight()}\n$entry');
        } else {
          await file.writeAsString(
            '${existing.trimRight()}\n\n$sectionHeader\n$entry',
          );
        }
      } else {
        await file.writeAsString('# CLAUDE.md\n\n$sectionHeader\n$entry');
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onSaved(path);
    } on Object {
      // Ignore write error.
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.partBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Codicons.book, size: 16, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '🧠 写入项目记忆胶囊 (CLAUDE.md)',
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _distilling ? null : _distillWithAi,
                    icon: _distilling
                        ? IdeSpinning(
                            Icon(Codicons.loading, size: 13, color: accent),
                          )
                        : Icon(Codicons.sparkle, size: 13, color: accent),
                    label: Text(
                      _distilling ? '提炼中…' : 'AI 提炼精简规范',
                      style: TextStyle(color: accent, fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (widget.projectClaudeMd != null)
                Row(
                  children: [
                    _TargetOptionChip(
                      label: '当前项目 (CLAUDE.md)',
                      selected: !_useGlobal,
                      onTap: () => setState(() => _useGlobal = false),
                    ),
                    const SizedBox(width: 8),
                    _TargetOptionChip(
                      label: '全局记忆 (~/.claude/CLAUDE.md)',
                      selected: _useGlobal,
                      onTap: () => setState(() => _useGlobal = true),
                    ),
                  ],
                ),
              const SizedBox(height: 6),
              Text(
                '目标文件：$_targetPath',
                style: TextStyle(color: AppColors.textFaint, fontSize: 11),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.bubbleFill,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.partBorder),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: TextField(
                  controller: _controller,
                  minLines: 4,
                  maxLines: 8,
                  style: TextStyle(color: AppColors.text, fontSize: 12.5),
                  decoration: const InputDecoration.collapsed(
                    hintText: '- 输入要让 AI 永久记住的项目规范或踩坑结论…',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      '取消',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: accent),
                    onPressed: _save,
                    icon: const Icon(Codicons.check, size: 14),
                    label: const Text('写入 CLAUDE.md', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TargetOptionChip extends StatelessWidget {
  const _TargetOptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? accent : AppColors.partBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? accent : AppColors.textMuted,
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 📤 Feature 3B: Export Turn & Full Session as Formatted Markdown
// ---------------------------------------------------------------------------

class ExportTurnButton extends StatefulWidget {
  const ExportTurnButton({
    super.key,
    required this.summary,
    required this.feed,
  });

  final TurnSummaryData summary;
  final ChatFeed feed;

  @override
  State<ExportTurnButton> createState() => _ExportTurnButtonState();
}

class _ExportTurnButtonState extends State<ExportTurnButton> {
  bool _exported = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _export({required bool fullSession}) async {
    final md = fullSession
        ? MarkdownExporter.formatFullSession(widget.feed)
        : MarkdownExporter.formatTurn(widget.summary);
    await Clipboard.setData(ClipboardData(text: md));
    String? savedPath;
    if (fullSession || HardwareKeyboard.instance.isShiftPressed) {
      savedPath = await MarkdownExporter.saveToDownloads(
        md,
        prefix: fullSession ? 'Byte-会话复盘' : 'Byte-单轮问答',
      );
    }
    if (!mounted) return;
    _timer?.cancel();
    setState(() => _exported = true);
    _timer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _exported = false);
    });
    IdeNotificationsScope.maybeOf(context)?.notify(
      IdeSeverity.info,
      savedPath != null
          ? '📤 已复制 Markdown 并保存至：$savedPath'
          : '📤 已复制精美 Markdown 笔记（按住 Shift 点击可同时另存为 .md 文件）',
    );
  }

  @override
  Widget build(BuildContext context) {
    return IdeHover(
      message: _exported
          ? '✅ 已导出 Markdown 笔记'
          : '📤 导出本轮精美 Markdown（按住 Shift 点击导出整场会话 .md 文件）',
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) => GestureDetector(
          onTap: () => unawaited(
            _export(fullSession: HardwareKeyboard.instance.isShiftPressed),
          ),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: hovered ? AppColors.hover : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              _exported ? Codicons.check : Codicons.markdown,
              size: 13,
              color: hovered || _exported
                  ? AppColors.text
                  : AppColors.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

abstract final class MarkdownExporter {
  static String formatTurn(TurnSummaryData s) {
    final buf = StringBuffer();
    buf.writeln('## 🙋 提问');
    buf.writeln();
    buf.writeln(s.promptText.trim());
    buf.writeln();
    if (s.editedFiles.isNotEmpty) {
      buf.writeln('### 📝 变更文件 (${s.editedFiles.length})');
      for (final f in s.editedFiles) {
        buf.writeln('- `${f.path}` (+${f.added} / -${f.removed})');
      }
      buf.writeln();
    }
    if (s.answerText != null && s.answerText!.trim().isNotEmpty) {
      buf.writeln('## 🤖 Byte 回答');
      buf.writeln();
      buf.writeln(s.answerText!.trim());
      buf.writeln();
    }
    final stats = <String>[
      if (s.worked != null) '耗时 ${AgentStep.formatDuration(s.worked!)}',
      if (s.usage?.tokensPerSecond case final speed?)
        '${speed.toStringAsFixed(1)} tok/s',
      if (s.usage?.totalTokens case final tok?) '$tok tokens',
    ];
    if (stats.isNotEmpty) {
      buf.writeln('> ${stats.join(' · ')}');
    }
    return buf.toString();
  }

  static String formatFullSession(ChatFeed feed) {
    final buf = StringBuffer();
    final now = DateTime.now().toIso8601String().substring(0, 19).replaceAll('T', ' ');
    buf.writeln('# 🦅 Byte 会话复盘笔记');
    buf.writeln();
    buf.writeln('- **导出时间**：`$now`');
    if (feed is ChatSession && feed.root != null) {
      buf.writeln('- **项目目录**：`${feed.root}`');
    }
    buf.writeln();

    final pins = ChatPinsStore.instance.pinsFor(feed);
    if (pins.isNotEmpty) {
      buf.writeln('## 📌 置顶关键结论 (${pins.length})');
      buf.writeln();
      for (final pin in pins) {
        buf.writeln('### 🔹 ${pin.promptTitle}');
        buf.writeln(pin.answer.trim());
        buf.writeln();
      }
      buf.writeln('---');
      buf.writeln();
    }

    buf.writeln('## 💬 对话全记录');
    buf.writeln();
    var turnNum = 0;
    for (var i = 0; i < feed.itemCount; i++) {
      final item = feed.itemAt(i);
      if (item is UserMessageItem && item.fromAgent == null) {
        turnNum++;
        var end = i;
        final words = <String>[];
        for (var j = i + 1; j < feed.itemCount; j++) {
          final next = feed.itemAt(j);
          if (next is UserMessageItem && next.fromAgent == null) break;
          end = j;
          if (next is AssistantTextItem) words.add(next.text);
        }
        final summary = TurnSummaryData.collect(
          feed,
          promptIndex: i,
          endIndex: end,
          answerText: words.isEmpty ? null : words.join('\n\n'),
        );
        buf.writeln('### #$turnNum 提问');
        buf.writeln();
        buf.writeln(summary.promptText.trim());
        buf.writeln();
        if (summary.editedFiles.isNotEmpty) {
          buf.writeln('**修改文件：**');
          for (final f in summary.editedFiles) {
            buf.writeln('- `${f.path}` (+${f.added} / -${f.removed})');
          }
          buf.writeln();
        }
        if (summary.answerText != null) {
          buf.writeln(summary.answerText!.trim());
          buf.writeln();
        }
        buf.writeln('---');
        buf.writeln();
      }
    }
    return buf.toString();
  }

  static Future<String?> saveToDownloads(
    String markdown, {
    required String prefix,
  }) async {
    try {
      final home = Platform.environment['HOME'];
      final dir = home != null && Directory('$home/Downloads').existsSync()
          ? '$home/Downloads'
          : Directory.systemTemp.path;
      final ts = DateTime.now()
          .toIso8601String()
          .substring(0, 19)
          .replaceAll(':', '-')
          .replaceAll('T', '_');
      final path = p.join(dir, '$prefix-$ts.md');
      await File(path).writeAsString(markdown);
      return path;
    } on Object {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// ⚔️ Feature 4A: Model PK Comparison Button & Side-by-Side Comparison Card
// ---------------------------------------------------------------------------

class ModelPkButton extends StatelessWidget {
  const ModelPkButton({
    super.key,
    required this.onPickChallenger,
  });

  final ValueChanged<({String providerName, String modelId, String modelLabel})>
  onPickChallenger;

  Future<void> _openPicker(BuildContext context) async {
    unawaited(ProviderHealthMonitor.instance.pingAll());
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final providers = ModelProviders.current.enabled;
    final entries = <IdeMenuEntry>[];

    for (final provider in providers) {
      final ping = ProviderHealthMonitor.instance.pingOf(provider.id);
      final pingBadge = ping.shortLabel.isEmpty ? '' : '  ${ping.shortLabel}';
      final models = provider.models.isNotEmpty
          ? provider.models
          : [const ProviderModel(id: 'haiku')];
      for (final m in models.take(4)) {
        final fullId = modelRef(provider.id, m.id);
        final label = m.label?.trim().isNotEmpty == true ? m.label! : m.id;
        entries.add(
          IdeMenuAction(
            '⚔️ ${provider.name} · $label$pingBadge',
            onSelected: () => onPickChallenger((
              providerName: provider.name,
              modelId: fullId,
              modelLabel: label,
            )),
          ),
        );
      }
    }

    if (entries.isEmpty) {
      entries.add(
        IdeMenuAction(
          '⚔️ Claude Haiku (默认对照)',
          onSelected: () => onPickChallenger((
            providerName: 'Claude',
            modelId: 'haiku',
            modelLabel: 'Haiku',
          )),
        ),
      );
    }

    await showIdeMenu(context, anchor: anchor, entries: entries);
  }

  @override
  Widget build(BuildContext context) {
    return IdeHover(
      message: '⚔️ 换个模型同题对比 PK（并排盲测对比速度与回答质量）',
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) => GestureDetector(
          onTap: () => unawaited(_openPicker(context)),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: hovered ? AppColors.hover : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              Codicons.arrowSwap,
              size: 13,
              color: hovered ? AppColors.text : AppColors.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

class ModelPkComparisonCard extends StatefulWidget {
  const ModelPkComparisonCard({
    super.key,
    required this.promptText,
    required this.originalAnswer,
    required this.challenger,
    this.session,
    required this.onClose,
  });

  final String promptText;
  final String originalAnswer;
  final ({String providerName, String modelId, String modelLabel}) challenger;
  final ChatSession? session;
  final VoidCallback onClose;

  @override
  State<ModelPkComparisonCard> createState() => _ModelPkComparisonCardState();
}

class _ModelPkComparisonCardState extends State<ModelPkComparisonCard> {
  bool _loading = true;
  String? _challengerAnswer;
  String? _error;
  Duration? _duration;

  @override
  void initState() {
    super.initState();
    unawaited(_runChallenger());
  }

  @override
  void didUpdateWidget(ModelPkComparisonCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.challenger.modelId != widget.challenger.modelId) {
      unawaited(_runChallenger());
    }
  }

  Future<void> _runChallenger() async {
    setState(() {
      _loading = true;
      _error = null;
      _challengerAnswer = null;
    });
    final sw = Stopwatch()..start();
    try {
      final reply = await askClaudeHaiku(
        'Answer the user request accurately, concisely, and in the same language.',
        widget.promptText,
        model: widget.challenger.modelId,
        exact: true,
        location: widget.session?.kernelContext.cwd,
      );
      sw.stop();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _challengerAnswer = reply.trim();
        _duration = sw.elapsed;
      });
    } on Object catch (err) {
      sw.stop();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$err';
        _duration = sw.elapsed;
      });
    }
  }

  void _adoptModel() {
    final session = widget.session;
    final models = session?.models;
    if (session == null || models == null) return;
    for (final option in models.options) {
      if (option.id == widget.challenger.modelId) {
        models.onSelected(option);
        IdeNotificationsScope.maybeOf(context)?.notify(
          IdeSeverity.info,
          '⚡ 已将当前会话切换至 ${widget.challenger.providerName} · ${widget.challenger.modelLabel}',
        );
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    final c = widget.challenger;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Codicons.arrowSwap, size: 14, color: accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '⚔️ 同题模型并排 PK：当前回答 vs ${c.providerName} · ${c.modelLabel}',
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (!_loading && _challengerAnswer != null) ...[
                  if (widget.session != null)
                    TextButton(
                      onPressed: _adoptModel,
                      child: Text(
                        '切换会话为此模型',
                        style: TextStyle(color: accent, fontSize: 11.5),
                      ),
                    ),
                  TextButton(
                    onPressed: () => unawaited(
                      Clipboard.setData(
                        ClipboardData(text: _challengerAnswer!),
                      ),
                    ),
                    child: Text(
                      '复制挑战者回答',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                    ),
                  ),
                ],
                IconButton(
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                  onPressed: widget.onClose,
                  icon: Icon(Codicons.close, size: 14, color: AppColors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 8),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _PkColumnBox(
                      title: '🅰️ 原模型回答 (${widget.originalAnswer.length} 字)',
                      body: widget.originalAnswer,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _PkColumnBox(
                      title:
                          '🅱️ ${c.providerName} · ${c.modelLabel}${_duration != null ? ' (${(_duration!.inMilliseconds / 1000).toStringAsFixed(1)}s)' : ''}',
                      body: _loading
                          ? '正在请求 ${c.providerName} · ${c.modelLabel} 同题作答…'
                          : (_error != null
                                ? '❌ 请求失败：$_error'
                                : (_challengerAnswer ?? '')),
                      loading: _loading,
                      highlighted: true,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PkColumnBox extends StatelessWidget {
  const _PkColumnBox({
    required this.title,
    required this.body,
    this.loading = false,
    this.highlighted = false,
  });

  final String title;
  final String body;
  final bool loading;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.bubbleFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: highlighted
              ? accent.withValues(alpha: 0.35)
              : AppColors.partBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (loading) ...[
                IdeSpinning(Icon(Codicons.loading, size: 12, color: accent)),
                const SizedBox(width: 5),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: highlighted ? accent : AppColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Flexible(
            child: SingleChildScrollView(
              child: SelectableText(
                body,
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

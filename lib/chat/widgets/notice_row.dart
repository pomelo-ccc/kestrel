import 'package:flutter/material.dart';

import '../../kernel/kernel_types.dart';
import '../../models/provider_health.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../chat_models.dart';
import '../chat_session.dart';
import 'hover_builder.dart';
import 'markdown_view.dart';

/// A line from the runtime rather than the agent: a compaction divider, a
/// retry or error, a hint, or the output of a command run in the session.
class NoticeRow extends StatelessWidget {
  const NoticeRow({super.key, required this.item, this.session});

  final NoticeItem item;
  final ChatSession? session;

  @override
  Widget build(BuildContext context) {
    final text = item.text;
    switch (item.kind) {
      case NoticeKind.compaction:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(child: Divider(color: AppColors.partBorder)),
              const SizedBox(width: 10),
              Icon(
                Icons.compress_rounded,
                size: 13,
                color: AppColors.textFaint,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  style: TextStyle(color: AppColors.textFaint, fontSize: 12),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Divider(color: AppColors.partBorder)),
            ],
          ),
        );
      case NoticeKind.command:
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.partBorder),
          ),
          child: MarkdownView(
            text,
            style: MarkdownView.baseStyle.copyWith(fontSize: 13),
          ),
        );
      case NoticeKind.retry ||
          NoticeKind.error ||
          NoticeKind.info ||
          NoticeKind.warning:
        final error = themeColors['errorForeground'];
        final (icon, color) = switch (item.kind) {
          NoticeKind.error => (Icons.error_outline_rounded, error),
          NoticeKind.warning || NoticeKind.retry => (
            Icons.warning_amber_rounded,
            themeColors['notificationsWarningIcon.foreground'],
          ),
          _ => (Icons.info_outline_rounded, AppColors.textMuted),
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 14, color: color),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        color: item.kind == NoticeKind.error
                            ? error
                            : AppColors.textMuted,
                        fontSize: 12.5,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
              if (item.kind == NoticeKind.error && session != null)
                _ErrorRecoveryActions(session: session!, errorText: text),
            ],
          ),
        );
    }
  }
}

class _ErrorRecoveryActions extends StatelessWidget {
  const _ErrorRecoveryActions({
    required this.session,
    required this.errorText,
  });

  final ChatSession session;
  final String errorText;

  UserMessageItem? _lastUserPrompt() {
    for (var i = session.itemCount - 1; i >= 0; i--) {
      if (session.itemAt(i) case final UserMessageItem msg
          when msg.fromAgent == null) {
        return msg;
      }
    }
    return null;
  }

  void _retry({KernelOption? switchModel}) {
    final last = _lastUserPrompt();
    if (last == null || session.isStreaming) return;
    if (switchModel != null) {
      session.models?.onSelected(switchModel);
    }
    session.send(
      ComposerMessage(text: last.text, images: last.images),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, ProviderHealthMonitor.instance]),
      builder: (context, _) {
        if (session.isStreaming || _lastUserPrompt() == null) {
          return const SizedBox.shrink();
        }
        final candidates = ProviderHealthMonitor.instance
            .backupCandidatesFor(session);
        return Padding(
          padding: const EdgeInsets.only(left: 22, top: 6, bottom: 2),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _RecoveryPill(
                icon: Codicons.refresh,
                label: '重试本条',
                onTap: _retry,
              ),
              for (final candidate in candidates.take(2))
                _RecoveryPill(
                  icon: Codicons.zap,
                  label:
                      '切换至 ${candidate.providerName} · ${candidate.option.label} 重试',
                  accent: true,
                  onTap: () => _retry(switchModel: candidate.option),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RecoveryPill extends StatelessWidget {
  const _RecoveryPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final fg = accent ? AppColors.accent : AppColors.textMuted;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
          decoration: BoxDecoration(
            color: accent
                ? AppColors.accent.withValues(alpha: hovered ? 0.18 : 0.10)
                : (hovered ? AppColors.hover : AppColors.surface),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: accent
                  ? AppColors.accent.withValues(alpha: 0.35)
                  : AppColors.partBorder,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: fg),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: hovered && !accent ? AppColors.text : fg,
                  fontSize: 11.5,
                  fontWeight: accent ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

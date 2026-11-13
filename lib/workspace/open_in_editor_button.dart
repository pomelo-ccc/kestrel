import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_keys.dart';
import '../chat/floating/floating_placement.dart';
import '../chat/widgets/hover_builder.dart';
import '../ide/ide_hover.dart';
import '../keybindings/chat_keybindings.dart';
import '../l10n/l10n.dart';
import '../sidebar/sidebar_menu.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'editor_launcher.dart';
import 'workspace.dart';

/// Split button for the title bar: opens [project] in the preferred editor
/// (the Fast Ide layout, or an app); its chevron switches which editor that
/// is (without opening it, and remembered), or copies the path. In the
/// colors of the IDE's [BackToChatButton], its counterpart there, and as
/// wide: the layout switches between them without a jump.
class OpenInEditorButton extends StatelessWidget {
  const OpenInEditorButton({
    super.key,
    required this.workspace,
    required this.project,
    this.agent,
  });

  final Workspace workspace;
  final Project project;

  /// The agent whose chat the IDE opens with [project]; null: the focused
  /// one's, where it is this project's.
  final AgentThread? agent;

  /// Opens a project in an editor; replaceable under test.
  @visibleForTesting
  static Future<bool> Function(Editor editor, String path) launch =
      openInEditor;

  void _open(Editor editor) {
    // A remote project's files are not this machine's: only the IDE's own
    // opens them.
    if (editor == Editor.fastIde || project.host != null) {
      // The project in the IDE, with the agent's chat there.
      final thread =
          agent ??
          (workspace.current?.project == project ? workspace.current : null);
      if (thread != null) {
        workspace.openInIde(thread);
      } else {
        workspace
          ..openIdeFolder(project.path)
          ..layout = WorkspaceLayout.ide;
      }
    } else {
      launch(editor, project.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editor = workspace.preferredEditor;
    final open = context.l10n.workspaceOpenIn(
      editor.localizedPlatformLabel(context.l10n),
    );
    return SidebarMenu(
      width: 200,
      placement: (side: FloatingSide.bottom, align: FloatingAlign.end),
      items: () => [
        for (final option in Editor.availableEditors)
          SidebarMenuItem(
            option.localizedPlatformLabel(context.l10n),
            icon: option.icon,
            checked: option == workspace.preferredEditor,
            onSelected: () => workspace.preferredEditor = option,
          ),
        SidebarMenuItem(
          context.l10n.workspaceCopyPath,
          icon: Codicons.copy,
          onSelected: () =>
              Clipboard.setData(ClipboardData(text: project.path)),
        ),
      ],
      builder: (context, menu) {
        final tooltip = editor == Editor.fastIde
            ? ChatKeys.titleWithKey(
                open,
                ChatCommandIds.openIde,
                ChatKeys.chatLayout,
              )
            : open;
        return IdeHover(
          message: tooltip,
          excludeFromSemantics: true,
          child: Semantics(
            button: true,
            label: open,
            excludeSemantics: true,
            child: HoverBuilder(
              cursor: SystemMouseCursors.click,
              builder: (context, hovered) => GestureDetector(
                onTap: () => _open(editor),
                onSecondaryTap: menu.open,
                onLongPress: menu.open,
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: menu.isOpen || hovered
                        ? themeColors['toolbar.hoverBackground']
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Icon(
                    editor.icon,
                    size: 14.5,
                    color: menu.isOpen || hovered
                        ? AppColors.text
                        : AppColors.textMuted,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

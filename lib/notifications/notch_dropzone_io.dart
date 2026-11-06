import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_feed.dart';
import '../chat/chat_models.dart';
import '../chat/composer/composer_files.dart';
import '../kernel/kernel_types.dart';
import '../window/app_windows.dart';
import '../workspace/workspace.dart';

typedef _NotchInitNative = Void Function();
typedef _NotchInitDart = void Function();

/// Bridges the native macOS Top-Notch Dropzone, Dynamic Island Live Activity (#22),
/// Top-Right PiP Mini Monitor (#23), global `⌃⇧A` Screenshot-to-Ask, and
/// global `⌃⇧S` Grab Selection (#24) (`libKestrelNotch.dylib`) with Kestrel's
/// active [Workspace] and composer.
abstract final class NotchDropzone {
  static final ValueNotifier<bool> pipEnabled = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> islandEnabled = ValueNotifier<bool>(true);

  static Timer? _timer;
  static bool _initialized = false;
  static final Map<AgentThread, ThreadStatus> _lastStatuses = {};
  static DateTime? _completedBannerUntil;
  static String? _completedBannerTitle;

  static void start({
    required Workspace workspace,
    required AppWindows windows,
  }) {
    if (_initialized ||
        !Platform.isMacOS ||
        Platform.environment['FLUTTER_TEST'] == 'true') {
      return;
    }
    _initialized = true;

    final inboxPath = p.join(
      Directory.systemTemp.path,
      'kestrel_notch_inbox.jsonl',
    );
    final statusPath = p.join(
      Directory.systemTemp.path,
      'kestrel_live_status.json',
    );
    try {
      final file = File(inboxPath);
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // Ignore cleanup errors.
    }

    _loadNativeLibrary();

    _timer = Timer.periodic(const Duration(milliseconds: 350), (_) {
      _pollInbox(inboxPath, workspace: workspace, windows: windows);
      _writeLiveStatus(statusPath, workspace: workspace);
    });
  }

  static void _loadNativeLibrary() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      p.normalize(p.join(exeDir, '..', 'Frameworks', 'libKestrelNotch.dylib')),
      p.join(exeDir, 'libKestrelNotch.dylib'),
    ];
    for (final path in candidates) {
      if (!File(path).existsSync()) continue;
      try {
        final dylib = DynamicLibrary.open(path);
        final init = dylib
            .lookupFunction<_NotchInitNative, _NotchInitDart>(
              'KestrelNotchInitDefault',
            );
        init();
        return;
      } on Object {
        // Continue trying fallback paths.
      }
    }
  }

  static AgentThread? _activeOrUrgentThread(Workspace workspace) {
    AgentThread? needsInputThread;
    AgentThread? runningThread;
    for (final thread in workspace.threads) {
      if (!thread.isOpen) continue;
      final status = thread.shownStatus;
      if (status == ThreadStatus.needsInput && needsInputThread == null) {
        needsInputThread = thread;
      } else if (status == ThreadStatus.running && runningThread == null) {
        runningThread = thread;
      }
    }
    return needsInputThread ?? runningThread ?? workspace.current;
  }

  static void _writeLiveStatus(
    String statusPath, {
    required Workspace workspace,
  }) {
    try {
      // Detect completion transitions for the 4-second Dynamic Island banner.
      for (final thread in workspace.threads) {
        if (!thread.isOpen) continue;
        final prev = _lastStatuses[thread];
        final curr = thread.shownStatus;
        if (prev == ThreadStatus.running &&
            (curr == ThreadStatus.idle || curr == ThreadStatus.unread)) {
          _completedBannerUntil = DateTime.now().add(
            const Duration(seconds: 4),
          );
          _completedBannerTitle = thread.title;
        }
        _lastStatuses[thread] = curr;
      }

      final target = _activeOrUrgentThread(workspace);
      final status = target?.shownStatus ?? ThreadStatus.idle;
      final title = target?.title ?? 'Kestrel';
      final session = (target != null && target.isOpen) ? target.session : null;
      final pending = session?.pendingInteraction;
      final needsApproval = pending is ApprovalRequest;

      String detail = '随时按 ⌃⇧A 截图提问，或按 ⌃⇧S 划词直问';
      if (pending is ApprovalRequest) {
        detail = '⚠️ 等待权限确认：${pending.toolName} (${pending.title})';
      } else if (pending is QuestionRequest) {
        detail = '❓ 等待您的选择：${pending.title}';
      } else if (session != null && status == ThreadStatus.running) {
        detail = _describeLatestActivity(session);
      } else if (target?.diff case (:final added, :final removed)) {
        detail = '已完成修改：+$added / -$removed 行';
      }

      final now = DateTime.now();
      final showCompletion =
          _completedBannerUntil != null && now.isBefore(_completedBannerUntil!);

      bool islandActive = false;
      String islandText = '';
      if (islandEnabled.value) {
        if (status == ThreadStatus.needsInput) {
          islandActive = true;
          islandText = '🟠 待确认 · $title · 点击处理';
        } else if (status == ThreadStatus.running) {
          islandActive = true;
          islandText = '🏝️ 执行中 · $title · $detail';
        } else if (showCompletion) {
          islandActive = true;
          islandText = '✅ 已完成 · ${_completedBannerTitle ?? title} · 点击查看';
        }
      }

      final pipStatus = switch (status) {
        ThreadStatus.needsInput => '🟠 待确认',
        ThreadStatus.running => '🟢 运行中',
        ThreadStatus.unread => '🔵 新回复',
        ThreadStatus.idle => '⚪ 待命',
      };

      final payload = jsonEncode({
        'islandActive': islandActive,
        'islandText': islandText,
        'pipVisible': pipEnabled.value,
        'pipTitle': '🦅 $title',
        'pipStatus': pipStatus,
        'pipDetail': detail,
        'needsApproval': needsApproval,
      });
      File(statusPath).writeAsStringSync(payload);
    } on Object {
      // Ignore transient I/O errors.
    }
  }

  static String _describeLatestActivity(ChatFeed session) {
    for (var i = session.itemCount - 1; i >= 0; i--) {
      final item = session.itemAt(i);
      switch (item) {
        case TerminalItem(:final command):
          return '💻 终端执行：$command';
        case CodeDiffItem(:final fileName, :final added, :final removed):
          return '📝 编辑 $fileName (+$added/-$removed)';
        case ToolCallItem(:final target, :final label):
          final desc = label != null && label.isNotEmpty
              ? '$label $target'
              : target;
          return '🔍 $desc';
        case ThinkingItem():
          return '💭 正在深度思考中…';
        case AssistantTextItem():
          return '✍️ 正在流式生成回复…';
        default:
          continue;
      }
    }
    return '⚡ 正在处理任务…';
  }

  static void _pollInbox(
    String inboxPath, {
    required Workspace workspace,
    required AppWindows windows,
  }) {
    final file = File(inboxPath);
    if (!file.existsSync()) return;
    final String raw;
    try {
      raw = file.readAsStringSync();
      file.deleteSync();
    } on Object {
      return;
    }
    if (raw.trim().isEmpty) return;

    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final data = jsonDecode(line);
        if (data is! Map) continue;
        final type = data['type'] as String?;

        if (type == 'close_pip') {
          pipEnabled.value = false;
          continue;
        }

        if (type == 'approve_active') {
          final target = _activeOrUrgentThread(workspace);
          if (target != null &&
              target.isOpen &&
              target.session.pendingInteraction is ApprovalRequest) {
            target.session.answer(
              const ApprovalAnswer(ApprovalDecision.allowOnce),
            );
          }
          continue;
        }

        if (type == 'focus_active') {
          final target = _activeOrUrgentThread(workspace);
          if (target != null) {
            workspace.layout = WorkspaceLayout.chat;
            if (windows.started) {
              windows.showAgent(target);
            }
          }
          continue;
        }

        final files = <ComposerFile>[
          if (data['files'] case final List<Object?> list)
            for (final item in list)
              if (item is String && item.trim().isNotEmpty)
                ComposerFile(
                  item,
                  directory: FileSystemEntity.isDirectorySync(item),
                ),
        ];
        final text = switch (data['text']) {
          final String s when s.trim().isNotEmpty => s.trim(),
          _ => null,
        };
        if (files.isEmpty && text == null) continue;

        var thread = workspace.current;
        if (thread == null && workspace.projects.isNotEmpty) {
          workspace.create();
          thread = workspace.current;
        }
        if (thread == null) continue;

        workspace.layout = WorkspaceLayout.chat;
        if (windows.started) {
          windows.showAgent(thread);
        }
        if (files.isNotEmpty) {
          thread.session.draft.insertFiles(files);
        }
        if (text != null) {
          if (type == 'selection') {
            final quoted = text
                .split('\n')
                .map((l) => '> $l')
                .join('\n');
            final existing = (thread.session.draft.content ?? '').trim();
            final nextText = existing.isEmpty
                ? '$quoted\n\n请帮我解释或分析以上选中内容：'
                : '$existing\n\n$quoted\n\n请帮我解释或分析以上选中内容：';
            thread.session.draft.restore(
              nextText,
              thread.session.draft.images,
            );
          } else {
            thread.session.draft.restore(text, thread.session.draft.images);
          }
        }
      } on Object {
        // Ignore malformed lines.
      }
    }
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

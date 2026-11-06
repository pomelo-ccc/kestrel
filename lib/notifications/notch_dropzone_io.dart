import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../chat/composer/composer_files.dart';
import '../window/app_windows.dart';
import '../workspace/workspace.dart';

typedef _NotchInitNative = Void Function();
typedef _NotchInitDart = void Function();

/// Bridges the native macOS Top-Notch Dropzone & global `⌃⇧A` Screenshot-to-Ask
/// (`libKestrelNotch.dylib`) with Kestrel's active [Workspace] and composer.
abstract final class NotchDropzone {
  static Timer? _timer;
  static bool _initialized = false;

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
    try {
      final file = File(inboxPath);
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // Ignore cleanup errors.
    }

    _loadNativeLibrary();

    _timer = Timer.periodic(const Duration(milliseconds: 350), (_) {
      _pollInbox(inboxPath, workspace: workspace, windows: windows);
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
          thread.session.draft.restore(text, const []);
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

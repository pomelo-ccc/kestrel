import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../claude_code/claude_code_transport.dart';
import '../claude_code/claude_environment.dart';
import '../claude_code/claude_path_setting.dart';

/// Built-in provider id for Antigravity CLI (`agy`) in Settings → Models
/// and the session model picker.
const antigravityBuiltinProviderId = 'antigravity-cli';

/// Settings → General → Antigravity CLI: custom executable path
/// (`antigravity.path` in settings.json).
abstract final class AntigravityPathSetting {
  static const settingKey = 'antigravity.path';

  static String? parse(Object? value) => switch (value) {
    final String path when path.trim().isNotEmpty => path.trim(),
    _ => null,
  };

  /// The path set now: main.dart reads it from settings.json.
  static String? Function() current = () => null;
}

/// A model offered by Antigravity CLI (`agy --output-format json models`).
class AntigravityModel {
  const AntigravityModel({
    required this.id,
    required this.label,
    this.description = '',
  });

  final String id;
  final String label;
  final String description;
}

/// Built-in and dynamically queried models of Antigravity CLI (`agy`).
abstract final class AntigravityModels {
  static const List<AntigravityModel> defaults = [
    AntigravityModel(
      id: 'gemini-4-argon-high',
      label: 'Gemini 4 Argon (High)',
      description: 'Antigravity CLI · High effort',
    ),
    AntigravityModel(
      id: 'gemini-4-argon-medium',
      label: 'Gemini 4 Argon (Medium)',
      description: 'Antigravity CLI · Medium effort',
    ),
    AntigravityModel(
      id: 'gemini-4-argon-low',
      label: 'Gemini 4 Argon (Low)',
      description: 'Antigravity CLI · Low effort',
    ),
    AntigravityModel(
      id: 'gemini-3.8-flash-high',
      label: 'Gemini 3.8 Flash (High)',
      description: 'Antigravity CLI · Fast & high effort',
    ),
    AntigravityModel(
      id: 'gemini-3.8-flash-medium',
      label: 'Gemini 3.8 Flash (Medium)',
      description: 'Antigravity CLI · Fast & medium effort',
    ),
    AntigravityModel(
      id: 'gemini-3.8-flash-low',
      label: 'Gemini 3.8 Flash (Low)',
      description: 'Antigravity CLI · Fast & low effort',
    ),
    AntigravityModel(
      id: 'claude-opus-5-5-high',
      label: 'Claude Opus 5.5 (High)',
      description: 'Antigravity CLI · High effort',
    ),
    AntigravityModel(
      id: 'claude-opus-5-5-medium',
      label: 'Claude Opus 5.5 (Medium)',
      description: 'Antigravity CLI · Medium effort',
    ),
    AntigravityModel(
      id: 'claude-opus-5-5-low',
      label: 'Claude Opus 5.5 (Low)',
      description: 'Antigravity CLI · Low effort',
    ),
    AntigravityModel(
      id: 'claude-sonnet-5-5-high',
      label: 'Claude Sonnet 5.5 (High)',
      description: 'Antigravity CLI · High effort',
    ),
    AntigravityModel(
      id: 'claude-sonnet-5-5-medium',
      label: 'Claude Sonnet 5.5 (Medium)',
      description: 'Antigravity CLI · Medium effort',
    ),
    AntigravityModel(
      id: 'claude-sonnet-5-5-low',
      label: 'Claude Sonnet 5.5 (Low)',
      description: 'Antigravity CLI · Low effort',
    ),
    AntigravityModel(
      id: 'gpt-oss-120b-medium',
      label: 'GPT-OSS 120B (Medium)',
      description: 'Antigravity CLI · Open-weight model',
    ),
  ];

  static List<AntigravityModel> _current = defaults;

  static List<AntigravityModel> get current => _current;

  static final Set<String> _knownIds = {
    for (final m in defaults) m.id,
  };

  /// Whether [model] is an `@antigravity-cli/<id>` reference or a known
  /// Antigravity CLI model ID.
  static bool isAntigravityModel(String? model) {
    if (model == null || model.isEmpty) return false;
    if (model.startsWith('@$antigravityBuiltinProviderId/')) return true;
    return _knownIds.contains(model);
  }

  /// Strips `@antigravity-cli/` prefix if present.
  static String bareModelId(String? model) {
    if (model == null || model.isEmpty) return 'gemini-4-argon-high';
    const prefix = '@$antigravityBuiltinProviderId/';
    if (model.startsWith(prefix)) {
      final bare = model.substring(prefix.length);
      return bare.isEmpty || bare == 'default' ? 'gemini-4-argon-high' : bare;
    }
    if (model == 'default') return 'gemini-4-argon-high';
    return model;
  }

  /// Label for [modelId].
  static String labelOf(String modelId) {
    final bare = bareModelId(modelId);
    for (final m in _current) {
      if (m.id == bare) return m.label;
    }
    return bare;
  }

  /// Updates the cached model list from `agy --output-format json models`.
  static void updateFromJson(Object? decoded) {
    if (decoded is! Map) return;
    final command = decoded['command'];
    if (command is! Map) return;
    final data = command['data'];
    if (data is! Map) return;
    final rawModels = data['models'];
    if (rawModels is! List || rawModels.isEmpty) return;
    final parsed = <AntigravityModel>[];
    for (final item in rawModels) {
      if (item is Map && item['id'] is String) {
        final id = (item['id'] as String).trim();
        final label = (item['label'] as String?)?.trim();
        if (id.isNotEmpty) {
          parsed.add(
            AntigravityModel(
              id: id,
              label: label != null && label.isNotEmpty ? label : id,
              description: 'Antigravity CLI',
            ),
          );
          _knownIds.add(id);
        }
      }
    }
    if (parsed.isNotEmpty) {
      _current = parsed;
    }
  }
}

/// Locates and inspects the Antigravity CLI (`agy`) on this machine.
abstract final class LocalAntigravity {
  static bool? _installed;
  static Map<String, String>? _shellEnv;

  static String _expandHome(String path, Map<String, String> env) {
    if (path == '~' || path.startsWith('~/') || path.startsWith(r'~\')) {
      final home =
          env['HOME'] ??
          env['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';
      return '$home${path.substring(1)}';
    }
    return path;
  }

  /// Candidate binary locations for `agy`, in priority order.
  static List<String> _candidates(Map<String, String> env) {
    final home =
        env['HOME'] ??
        env['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    final exe = Platform.isWindows ? 'agy.exe' : 'agy';
    final paths = <String>[
      if (home.isNotEmpty) ...[
        p.join(home, '.gemini', 'bin', exe),
        p.join(home, '.local', 'bin', exe),
        p.join(home, '.antigravity', 'antigravity', 'bin', exe),
      ],
      if (Platform.isMacOS) ...[
        '/Applications/Gemini.app/Contents/Helpers/agy',
        '/Applications/Antigravity.app/Contents/Resources/app/bin/agy',
        '/opt/homebrew/bin/agy',
        '/usr/local/bin/agy',
      ],
      if (Platform.isLinux) ...[
        '/usr/local/bin/agy',
        '/usr/bin/agy',
      ],
    ];
    final pathVar = env['PATH'] ?? Platform.environment['PATH'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    for (final dir in pathVar.split(sep)) {
      final trimmed = dir.trim();
      if (trimmed.isEmpty) continue;
      final candidate = p.join(trimmed, exe);
      if (!paths.contains(candidate)) {
        paths.add(candidate);
      }
    }
    return paths;
  }

  static String? _findExecutable(Map<String, String> env) {
    final configured = AntigravityPathSetting.current();
    if (configured != null) {
      final expanded = _expandHome(configured, env);
      return File(expanded).existsSync() ? expanded : null;
    }
    for (final candidate in _candidates(env)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Whether `agy` is installed on this machine.
  static bool installed() {
    if (kIsWeb) return false;
    final configured = AntigravityPathSetting.current();
    if (configured != null) {
      final env = _shellEnv ?? Platform.environment;
      return File(_expandHome(configured, env)).existsSync();
    }
    return _installed ??=
        _findExecutable(_shellEnv ?? Platform.environment) != null;
  }

  /// Looks for `agy` on the user's login shell PATH and refreshes its models.
  static Future<void> lookForInstall() async {
    if (kIsWeb) return;
    try {
      final env = await ClaudeEnvironment.of();
      _shellEnv = env;
      final exe = _findExecutable(env);
      _installed = exe != null;
      if (exe != null) {
        unawaited(_refreshModels(exe, env));
      }
    } on Object catch (error) {
      debugPrint('Antigravity CLI not looked for: $error');
    }
  }

  static Future<void> _refreshModels(
    String executable,
    Map<String, String> env,
  ) async {
    try {
      final result = await Process.run(
        executable,
        const ['--output-format', 'json', 'models'],
        environment: env,
      ).timeout(const Duration(seconds: 6));
      if (result.exitCode == 0) {
        final stdout = '${result.stdout}'.trim();
        for (final line in const LineSplitter().convert(stdout)) {
          if (line.trim().startsWith('{')) {
            AntigravityModels.updateFromJson(jsonDecode(line));
          }
        }
      }
    } on Object {
      // Fall back to AntigravityModels.defaults.
    }
  }

  /// Status of `agy` on this machine for Settings → General.
  static Future<LocalClaudeStatus?> status() async {
    if (kIsWeb) return null;
    final env = _shellEnv ?? await ClaudeEnvironment.of();
    _shellEnv = env;
    final configured = AntigravityPathSetting.current();
    if (configured != null) {
      final expanded = _expandHome(configured, env);
      if (!File(expanded).existsSync()) {
        _installed = false;
        return LocalClaudeFailed('找不到可执行文件：$expanded');
      }
      final version = await _versionOf(expanded, env);
      _installed = true;
      return LocalClaudeFound(expanded, version);
    }
    final exe = _findExecutable(env);
    if (exe == null) {
      _installed = false;
      return const LocalClaudeMissing();
    }
    _installed = true;
    final version = await _versionOf(exe, env);
    unawaited(_refreshModels(exe, env));
    return LocalClaudeFound(exe, version);
  }

  static Future<String?> _versionOf(
    String executable,
    Map<String, String> env,
  ) async {
    try {
      final result = await Process.run(
        executable,
        const ['--version'],
        environment: env,
      ).timeout(const Duration(seconds: 5));
      if (result.exitCode == 0) {
        final out = '${result.stdout}'.trim();
        if (out.isNotEmpty) return out.split('\n').first.trim();
      }
    } on Object {
      // Ignore version probe errors.
    }
    return null;
  }

  /// Locates the `agy` executable to launch a session, or throws
  /// [ClaudeUnavailable] if not found.
  static Future<({String executable, Map<String, String> environment})>
  locate() async {
    final env = _shellEnv ?? await ClaudeEnvironment.of();
    _shellEnv = env;
    final configured = AntigravityPathSetting.current();
    if (configured != null) {
      final expanded = _expandHome(configured, env);
      if (!File(expanded).existsSync()) {
        throw ClaudeUnavailable(
          'Antigravity CLI (agy) 未找到',
          detail:
              '在路径 $expanded 未找到可执行文件。\n'
              '请在「设置 → 通用 → Claude Code / 内核」中修正 Antigravity CLI 路径，或清空以自动查找。',
        );
      }
      return (executable: expanded, environment: env);
    }
    final exe = _findExecutable(env);
    if (exe == null) {
      throw const ClaudeUnavailable(
        '本机未找到 Antigravity CLI (agy)',
        detail:
            '请确认已安装 Antigravity (~/.gemini/bin/agy 或 ~/.local/bin/agy)，'
            '或在「设置 → 通用」中指定 agy 可执行文件路径。',
      );
    }
    return (executable: exe, environment: env);
  }
}

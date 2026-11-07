import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show AgentPaths, agentVersion;
import 'package:path/path.dart' as p;

import '../../network/network_proxy_io.dart';
import '../claude_code/claude_code_transport.dart';
import 'antigravity_cli.dart';

/// Starts a session on the Antigravity CLI (`agy`).
Future<ClaudeCodeTransport> startAntigravity(ClaudeLaunch launch) =>
    AntigravityTransport.start(launch);

/// Whether [launch] explicitly targets an Antigravity CLI model.
bool isAntigravityLaunch(ClaudeLaunch launch) =>
    AntigravityModels.isAntigravityModel(launch.model);

/// Adapts the Antigravity CLI (`agy --input-format stream-json
/// --output-format stream-json`) to [ClaudeCodeTransport].
///
/// Key design points:
/// 1. **Persistent Multi-Turn Process**: Keeps a single `agy` process alive
///    across turns (`stdin` stays open, one NDJSON user message per line),
///    preserving background tasks (`IsDaemon: true`), subagents, and avoiding
///    the 4–7s silent-auth cold start on subsequent turns.
/// 2. **Headless Tool Permissions**: Passes `--dangerously-skip-permissions`
///    in print mode so `tool_confirmation_manager.go` never soft-denies
///    `run_command` or file edits when there is no interactive TTY.
/// 3. **JSON Parameter Unquoting**: Unwraps JSON-encoded string values in
///    `tool_info.parameters` (`"\"/path\""` → `"/path"`, `"100"` → `100`).
/// 4. **Session Persistence**: Mirrors every user/assistant/tool message to
///    `~/.claude/projects/<project>/<sessionId>.jsonl` so Antigravity CLI
///    sessions appear in the sidebar, support Session Replay, and reload
///    their full transcript across app restarts.
class AntigravityTransport implements ClaudeCodeTransport {
  AntigravityTransport._({
    required this.executable,
    required this.environment,
    required this.launch,
  }) : _sessionId = (launch.resume != null && launch.resume!.isNotEmpty)
           ? launch.resume
           : null,
       _model = AntigravityModels.bareModelId(launch.model),
       _permissionMode = launch.permissionMode ?? 'default',
       _effort = launch.effort,
       _paths = AgentPaths.from(environment) {
    _live.add(this);
    _initSessionState();
  }

  static final Set<AntigravityTransport> _live = {};

  static Future<void> stopAll() async {
    for (final transport in [..._live]) {
      transport.close();
    }
  }

  static Future<ClaudeCodeTransport> start(ClaudeLaunch launch) async {
    if (!Directory(launch.cwd).existsSync()) {
      throw ClaudeFolderGone(launch.cwd);
    }
    final cli = await LocalAntigravity.locate();
    final proxy = await NetworkProxy.instance.environment();
    return AntigravityTransport._(
      executable: cli.executable,
      environment: {...cli.environment, ...proxy},
      launch: launch,
    );
  }

  final String executable;
  final Map<String, String> environment;
  final ClaudeLaunch launch;
  final AgentPaths _paths;

  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final Completer<void> _exited = Completer<void>();

  /// The session ID known to Byte / `.claude/projects`.
  String? _sessionId;

  /// The conversation ID known to `agy` (`~/.gemini/antigravity-cli/conversations`).
  String? _agyConversationId;

  _AntigravitySessionLog? _sessionLog;
  String? _pendingCustomTitle;
  bool _needsHistorySeed = false;

  String _model;
  String _permissionMode;
  String? _effort;
  bool _closed = false;

  /// Persistent `agy` process kept alive across turns.
  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  String? _spawnedModel;
  String? _spawnedModeFlag;
  String? _spawnedEffort;
  _ActiveTurn? _activeTurn;
  final Set<int> _completedToolSteps = {};

  bool _interrupted = false;
  int _turnCounter = 0;
  int _lastTotalTokens = 0;

  /// Queue of user turns to run sequentially.
  Future<void> _turnQueue = Future.value();

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _exited.future;

  void _initSessionState() {
    final id = _sessionId;
    if (id == null || id.isEmpty) return;

    final hasAgyConv = _hasAntigravityConversation(id);
    if (hasAgyConv) {
      _agyConversationId = id;
      if (launch.persist) {
        syncAntigravityTranscriptIfNeeded(
          cwd: launch.cwd,
          sessionId: id,
          paths: _paths,
          model: _model,
        );
      }
    } else {
      // Switching an existing Claude Code session to Antigravity CLI:
      // keep Byte's `_sessionId` intact and seed prior context on turn 1.
      _agyConversationId = null;
      _needsHistorySeed = true;
    }

    if (launch.persist) {
      _sessionLog = _AntigravitySessionLog(
        paths: _paths,
        cwd: launch.cwd,
        sessionId: id,
        persist: launch.persist,
      );
    }
  }

  bool _hasAntigravityConversation(String id) {
    final home = _paths.home;
    final convDir = p.join(home, '.gemini', 'antigravity-cli', 'conversations');
    if (File(p.join(convDir, '$id.db')).existsSync() ||
        File(p.join(convDir, '$id.pb')).existsSync()) {
      return true;
    }
    final brainTranscript = p.join(
      home,
      '.gemini',
      'antigravity-cli',
      'brain',
      id,
      '.system_generated',
      'logs',
      'transcript.jsonl',
    );
    return File(brainTranscript).existsSync();
  }

  void _bindConversationId(String convId) {
    if (convId.isEmpty) return;
    _agyConversationId = convId;
    if (_sessionId == null || _sessionId!.isEmpty) {
      _sessionId = convId;
      _emit({
        'type': 'system',
        'subtype': 'init',
        'session_id': convId,
        'model': _model,
        if (_effort != null) 'effort': _effort,
      });
    }
    if (_sessionLog == null && launch.persist && _sessionId != null) {
      _sessionLog = _AntigravitySessionLog(
        paths: _paths,
        cwd: launch.cwd,
        sessionId: _sessionId!,
        persist: launch.persist,
      );
      if (_pendingCustomTitle case final title?) {
        _pendingCustomTitle = null;
        _sessionLog!.noteTitle(title);
      }
    }
  }

  void _emit(Map<String, Object?> message) {
    if (!_closed && !_messages.isClosed) {
      _messages.add(message);
    }
  }

  @override
  void write(Map<String, Object?> message) {
    if (_closed) return;
    switch (message['type']) {
      case 'control_request':
        _handleControlRequest(message);
      case 'user':
        _turnQueue = _turnQueue.then((_) => _runUserTurn(message));
    }
  }

  void _handleControlRequest(Map<String, Object?> message) {
    final requestId = message['request_id'] as String?;
    final request = (message['request'] as Map?)?.cast<String, Object?>();
    if (requestId == null || request == null) return;
    final subtype = request['subtype'] as String? ?? '';

    void respondSuccess([Map<String, Object?> payload = const {}]) {
      _emit({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': requestId,
          'response': payload,
        },
      });
    }

    switch (subtype) {
      case 'initialize':
        final models = AntigravityModels.current;
        respondSuccess({
          'account': const {'subscriptionType': 'Antigravity CLI'},
          'models': [
            for (final m in models)
              {
                'value': m.id,
                'displayName': m.label,
                'description': m.description,
                'supportsEffort': true,
                'supportedEffortLevels': const ['low', 'medium', 'high'],
                'supportsAutoMode': true,
              },
          ],
          'commands': const [
            {
              'name': 'compact',
              'description': 'Compact conversation context',
              'builtin': true,
            },
            {
              'name': 'clear',
              'description': 'Start a fresh conversation',
              'builtin': true,
            },
          ],
        });
        _emit({
          'type': 'system',
          'subtype': 'init',
          if (_sessionId case final id? when id.isNotEmpty) 'session_id': id,
          'model': _model,
          'permissionMode': _permissionMode,
          if (_effort != null) 'effort': _effort,
        });
      case 'set_permission_mode':
        if (request['mode'] case final String mode) {
          _permissionMode = mode;
        }
        respondSuccess();
        _emit({
          'type': 'system',
          'subtype': 'status',
          'permissionMode': _permissionMode,
        });
      case 'set_model':
        if (request['model'] case final String model) {
          _model = AntigravityModels.bareModelId(model);
        }
        respondSuccess();
      case 'apply_flag_settings':
        if (request['settings'] case final Map settings) {
          if (settings['effortLevel'] case final String effort) {
            _effort = effort;
          }
        }
        respondSuccess();
      case 'get_settings':
        respondSuccess({
          'applied': {
            'model': _model,
            if (_effort != null) 'effort': _effort,
          },
        });
      case 'rename_session':
        if (request['title'] case final String title
            when title.trim().isNotEmpty) {
          final trimmed = title.trim();
          if (_sessionLog != null) {
            _sessionLog!.noteTitle(trimmed);
          } else {
            _pendingCustomTitle = trimmed;
          }
        }
        respondSuccess();
      case 'get_context_usage':
        const maxTokens = 1000000;
        final used = _lastTotalTokens;
        respondSuccess({
          'maxTokens': maxTokens,
          'rawMaxTokens': maxTokens,
          'totalTokens': used,
          'categories': [
            {'name': 'Conversation', 'tokens': used, 'kind': 'used'},
            {
              'name': 'Available',
              'tokens': (maxTokens - used).clamp(0, maxTokens),
              'kind': 'free',
            },
          ],
        });
      case 'interrupt':
        _interrupted = true;
        unawaited(_stopProcess(notifyActiveTurn: true));
        respondSuccess();
      case 'cancel_async_message':
        respondSuccess(const {'cancelled': true});
      case 'get_usage':
        respondSuccess(const {'rate_limits_available': false});
      default:
        respondSuccess();
    }
  }

  Future<String> _extractPrompt(Map<String, Object?> userMessage) async {
    final msg = userMessage['message'];
    if (msg is! Map) return '';
    final content = msg['content'];
    if (content is String) return content;
    if (content is! List) return '';

    final parts = <String>[];
    var imageIndex = 0;
    for (final raw in content) {
      if (raw is! Map) continue;
      switch (raw['type']) {
        case 'text':
          final text = '${raw['text'] ?? ''}'.trim();
          if (text.isNotEmpty) parts.add(text);
        case 'image':
          final source = raw['source'];
          if (source is Map && source['type'] == 'base64') {
            final data = source['data'] as String?;
            final mediaType = source['media_type'] as String? ?? 'image/png';
            if (data != null && data.isNotEmpty) {
              try {
                final bytes = base64Decode(data);
                final ext = mediaType.contains('jpeg') ||
                        mediaType.contains('jpg')
                    ? 'jpg'
                    : mediaType.contains('webp')
                    ? 'webp'
                    : 'png';
                imageIndex++;
                final tempFile = File(
                  p.join(
                    Directory.systemTemp.path,
                    'byte_agy_img_${DateTime.now().millisecondsSinceEpoch}_$imageIndex.$ext',
                  ),
                );
                await tempFile.writeAsBytes(bytes);
                parts.add(
                  '[Attached image #$imageIndex saved at ${tempFile.path} — use read_file to inspect it]',
                );
              } on Object {
                // Ignore malformed base64 image.
              }
            }
          }
      }
    }
    return parts.join('\n\n');
  }

  String get _effectiveModeFlag =>
      _permissionMode == 'plan' ? 'plan' : 'agent';

  List<String> _buildArguments() {
    final args = <String>[
      '--input-format=stream-json',
      '--output-format=stream-json',
      if (_agyConversationId case final id? when id.isNotEmpty)
        '--conversation=$id',
      if (_model.isNotEmpty && _model != 'default') '--model=$_model',
      if (_effort case final effort?
          when const {'low', 'medium', 'high', 'xhigh', 'max'}.contains(effort))
        '--effort=$effort',
      if (_permissionMode == 'plan') '--mode=plan',
      // Always pass --dangerously-skip-permissions in headless print mode so
      // tool_confirmation_manager.go never soft-denies RunCommand / file edits
      // when there is no interactive TTY prompt channel.
      '--dangerously-skip-permissions',
      for (final dir in launch.directories) '--add-dir=$dir',
      '-p=',
    ];
    return args;
  }

  Future<({Process process, bool reused})> _ensureProcess() async {
    if (_process != null &&
        _spawnedModel == _model &&
        _spawnedModeFlag == _effectiveModeFlag &&
        _spawnedEffort == _effort) {
      return (process: _process!, reused: true);
    }
    await _stopProcess(notifyActiveTurn: false);

    final args = _buildArguments();
    final process = await Process.start(
      executable,
      args,
      workingDirectory: launch.cwd,
      environment: environment,
    );
    _process = process;
    _completedToolSteps.clear();
    _spawnedModel = _model;
    _spawnedModeFlag = _effectiveModeFlag;
    _spawnedEffort = _effort;

    _stdoutSub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) => _activeTurn?.handleLine(line),
          onError: (Object e) => _activeTurn?.handleStderr('$e'),
        );
    _stderrSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) => _activeTurn?.handleStderr(line),
          onError: (Object e) => _activeTurn?.handleStderr('$e'),
        );

    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) {
          _process = null;
          unawaited(_stdoutSub?.cancel());
          unawaited(_stderrSub?.cancel());
          _stdoutSub = null;
          _stderrSub = null;
          _activeTurn?.handleProcessExit(code);
        }
      }),
    );

    return (process: process, reused: false);
  }

  Future<void> _stopProcess({bool notifyActiveTurn = false}) async {
    final proc = _process;
    _process = null;
    final outSub = _stdoutSub;
    final errSub = _stderrSub;
    _stdoutSub = null;
    _stderrSub = null;
    if (proc != null) {
      try {
        proc.kill();
      } on Object {
        // Ignore if already exited.
      }
    }
    await outSub?.cancel();
    await errSub?.cancel();
    if (notifyActiveTurn) {
      _activeTurn?.handleProcessExit(-1);
    }
  }

  Future<void> _runUserTurn(Map<String, Object?> userMessage) async {
    if (_closed) return;
    var prompt = await _extractPrompt(userMessage);
    if (prompt.trim().isEmpty) return;

    if (prompt.trim() == '/clear') {
      await _stopProcess();
      _agyConversationId = null;
      _sessionId = null;
      _sessionLog = null;
      _lastTotalTokens = 0;
      _emit({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': '',
        'duration_ms': 0,
      });
      return;
    }

    if (_needsHistorySeed && _sessionLog != null) {
      _needsHistorySeed = false;
      final priorSummary = _sessionLog!.buildRecentContextSummary();
      if (priorSummary.isNotEmpty) {
        prompt =
            '<CONVERSATION_CONTEXT>\n'
            'Previous turns in this session before switching to Antigravity CLI:\n'
            '$priorSummary\n'
            '</CONVERSATION_CONTEXT>\n\n'
            '$prompt';
      }
    }

    final turnId = ++_turnCounter;
    _interrupted = false;

    Map<String, Object?>? pendingUserRecord = {
      'type': 'user',
      'message': userMessage['message'],
      if (userMessage['uuid'] case final String id when id.isNotEmpty)
        'uuid': id,
    };
    if (_sessionLog != null) {
      _sessionLog!.append(pendingUserRecord);
      pendingUserRecord = null;
    }

    _emit({
      'type': 'system',
      'subtype': 'session_state_changed',
      'state': 'working',
    });

    final turn = _ActiveTurn(
      transport: this,
      turnId: turnId,
      onConversationBound: (convId) {
        _bindConversationId(convId);
        if (pendingUserRecord != null && _sessionLog != null) {
          _sessionLog!.append(pendingUserRecord!);
          pendingUserRecord = null;
        }
      },
    );
    _activeTurn = turn;

    final payload = jsonEncode({
      'event': 'user',
      'message': {'role': 'user', 'content': prompt},
    });

    Future<bool> runOnce(_ActiveTurn active) async {
      _activeTurn = active;
      var (:process, :reused) = await _ensureProcess();
      active.reusedProcess = reused;
      try {
        process.stdin.writeln(payload);
        await process.stdin.flush();
      } on Object {
        // Stale or closed stdin pipe on reused process; respawn once.
        await _stopProcess(notifyActiveTurn: false);
        active.reusedProcess = false;
        _activeTurn = active;
        (:process, :reused) = await _ensureProcess();
        process.stdin.writeln(payload);
        await process.stdin.flush();
      }
      await active.done.future;
      return active.needsFreshRetry;
    }

    try {
      final retry = await runOnce(turn);
      if (retry && !_interrupted && !_closed) {
        final freshTurn = _ActiveTurn(
          transport: this,
          turnId: turnId,
          onConversationBound: turn.onConversationBound,
        );
        await runOnce(freshTurn);
      }
    } on ProcessException catch (error) {
      _activeTurn = null;
      _emit({
        'type': 'result',
        'subtype': 'error',
        'is_error': true,
        'result': 'Antigravity CLI 启动失败：${error.message}',
      });
      _emit({
        'type': 'system',
        'subtype': 'session_state_changed',
        'state': 'idle',
      });
      return;
    } on Object catch (error) {
      _activeTurn = null;
      _emit({
        'type': 'result',
        'subtype': 'error',
        'is_error': true,
        'result': 'Antigravity CLI 发送消息失败：$error',
      });
      _emit({
        'type': 'system',
        'subtype': 'session_state_changed',
        'state': 'idle',
      });
      return;
    }

    _activeTurn = null;

    _emit({
      'type': 'system',
      'subtype': 'session_state_changed',
      'state': 'idle',
    });
  }

  Map<String, Object?>? _mapUsage(Object? rawUsage) {
    if (rawUsage is! Map) return null;
    final inputTokens = (rawUsage['input_tokens'] as num?)?.round() ?? 0;
    final outputTokens = (rawUsage['output_tokens'] as num?)?.round() ?? 0;
    final cacheRead = (rawUsage['cache_read_tokens'] as num?)?.round() ?? 0;
    final thinkingTokens = (rawUsage['thinking_tokens'] as num?)?.round();
    final totalTokens = (rawUsage['total_tokens'] as num?)?.round();
    if (totalTokens != null && totalTokens > 0) {
      _lastTotalTokens = totalTokens + cacheRead;
    } else if (inputTokens + outputTokens + cacheRead > 0) {
      _lastTotalTokens = inputTokens + outputTokens + cacheRead;
    }
    return {
      'input_tokens': inputTokens,
      'output_tokens': outputTokens,
      if (cacheRead > 0) 'cache_read_input_tokens': cacheRead,
      if (thinkingTokens != null)
        'output_tokens_details': {'thinking_tokens': thinkingTokens},
    };
  }

  /// Normalizes `tool_info.parameters` where `agy` serializes each map value
  /// as a JSON-encoded string (e.g. `"\"/path/to/file\""` or `"100"`).
  static Map<String, Object?> normalizeToolParams(
    Map<String, Object?> rawParams,
  ) {
    final out = <String, Object?>{};
    for (final MapEntry(:key, :value) in rawParams.entries) {
      out[key] = _decodeParamValue(value);
    }
    return out;
  }

  static Object? _decodeParamValue(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) {
        try {
          return jsonDecode(trimmed);
        } on FormatException {
          return value;
        }
      }
    }
    return value;
  }

  /// Strips verbose `Created At:` / `Completed At:` headers from `agy` tool
  /// outputs so tool cards in Byte look clean.
  static String cleanToolOutput(String rawName, String output) {
    var cleaned = output.replaceAll('\r\n', '\n');
    cleaned = cleaned.replaceFirst(
      RegExp(r'^Created At: [^\n]+\n(?:Completed At: [^\n]+\n)?'),
      '',
    );
    if (rawName == 'run_command' || rawName == 'execute_command') {
      cleaned = cleaned.replaceFirst(
        RegExp(r'^Command exited with code 0\.\n+(?:Command output:\n)?'),
        '',
      );
    }
    return cleaned.trim();
  }

  /// Maps an Antigravity CLI tool call (`read_file`, `edit_file`, `write_file`,
  /// `run_command`, `grep_search`, `find_by_name`, etc.) to Claude Code's
  /// tool schema so `ClaudeTranslator` renders rich native cards and diffs.
  static ({
    String name,
    Map<String, Object?> input,
    Map<String, Object?>? structuredResult,
  })
  mapTool(
    String rawName,
    Map<String, Object?> rawParams,
    String output, {
    String defaultCwd = '',
  }) {
    final params = normalizeToolParams(rawParams);

    String? str(String key) => switch (params[key]) {
      final String s when s.isNotEmpty => s,
      _ => null,
    };

    int? numInt(String key) => switch (params[key]) {
      final num n => n.round(),
      final String s => int.tryParse(s.trim()),
      _ => null,
    };

    switch (rawName) {
      case 'read_file' || 'view_file' || 'view_file_outline' || 'view_code_item':
        final filePath =
            str('Path') ??
            str('AbsolutePath') ??
            str('FilePath') ??
            str('path') ??
            '';
        final start = numInt('StartLine');
        final end = numInt('EndLine');
        return (
          name: 'Read',
          input: {
            'file_path': filePath,
            if (start != null && end != null && end >= start) ...{
              'offset': start,
              'limit': end - start + 1,
            },
          },
          structuredResult: null,
        );

      case 'write_file' || 'write_to_file' || 'create_file':
        final filePath =
            str('Path') ??
            str('TargetFile') ??
            str('FilePath') ??
            str('path') ??
            '';
        final content =
            str('Content') ?? str('CodeContent') ?? str('content') ?? '';
        return (
          name: 'Write',
          input: {'file_path': filePath, 'content': content},
          structuredResult: filePath.isNotEmpty && content.isNotEmpty
              ? {
                  'type': 'create',
                  'filePath': filePath,
                  'content': content,
                }
              : null,
        );

      case 'edit_file' || 'replace_file_content':
        final filePath =
            str('Path') ??
            str('TargetFile') ??
            str('FilePath') ??
            str('path') ??
            '';
        final oldStr = str('Target') ?? str('TargetContent') ?? '';
        final newStr = str('Replacement') ?? str('ReplacementContent') ?? '';
        return (
          name: 'Edit',
          input: {
            'file_path': filePath,
            'old_string': oldStr,
            'new_string': newStr,
          },
          structuredResult: filePath.isNotEmpty &&
                  (oldStr.isNotEmpty || newStr.isNotEmpty)
              ? {
                  'filePath': filePath,
                  'structuredPatch': [
                    _buildHunk(oldStr, newStr),
                  ],
                }
              : null,
        );

      case 'multi_replace_file_content':
        final filePath =
            str('Path') ??
            str('TargetFile') ??
            str('FilePath') ??
            str('path') ??
            '';
        final chunks = params['ReplacementChunks'];
        final edits = <Map<String, Object?>>[];
        final hunks = <Map<String, Object?>>[];
        if (chunks is List) {
          for (final rawChunk in chunks) {
            if (rawChunk is Map) {
              final oldStr = '${rawChunk['TargetContent'] ?? ''}';
              final newStr = '${rawChunk['ReplacementContent'] ?? ''}';
              final startLine = switch (rawChunk['StartLine']) {
                final num n => n.round(),
                final String s => int.tryParse(s.trim()) ?? 1,
                _ => 1,
              };
              edits.add({'old_string': oldStr, 'new_string': newStr});
              hunks.add(_buildHunk(oldStr, newStr, startLine: startLine));
            }
          }
        }
        return (
          name: 'MultiEdit',
          input: {'file_path': filePath, 'edits': edits},
          structuredResult: filePath.isNotEmpty && hunks.isNotEmpty
              ? {'filePath': filePath, 'structuredPatch': hunks}
              : null,
        );

      case 'run_command' || 'execute_command':
        final cmd =
            str('CommandLine') ?? str('Command') ?? str('command') ?? '';
        final desc = str('toolSummary') ?? str('Description');
        return (
          name: 'Bash',
          input: {
            'command': cmd,
            'description': ?desc,
          },
          structuredResult: {'stdout': output, 'stderr': ''},
        );

      case 'manage_task' || 'command_status':
        final action = str('Action') ?? 'status';
        final taskId = str('TaskId') ?? str('CommandId') ?? '';
        final cmdDesc = taskId.isNotEmpty
            ? 'manage_task $action ($taskId)'
            : 'manage_task $action';
        return (
          name: 'Bash',
          input: {
            'command': cmdDesc,
            'description': 'Manage background task ($action)',
          },
          structuredResult: {'stdout': output, 'stderr': ''},
        );

      case 'grep_search' || 'ripgrep':
        final pattern =
            str('Query') ?? str('Pattern') ?? str('pattern') ?? '';
        return (
          name: 'Grep',
          input: {'pattern': pattern},
          structuredResult: null,
        );

      case 'find_by_name':
        final pattern =
            str('Pattern') ?? str('Query') ?? str('pattern') ?? '*';
        return (
          name: 'Glob',
          input: {'pattern': pattern},
          structuredResult: null,
        );

      case 'list_dir' || 'list_directory' || 'list_files':
        final dirPath =
            str('DirectoryPath') ??
            str('Path') ??
            str('path') ??
            defaultCwd;
        return (
          name: 'LS',
          input: {'path': dirPath},
          structuredResult: null,
        );

      case 'search_web':
        final query = str('query') ?? str('Query') ?? '';
        return (
          name: 'WebSearch',
          input: {'query': query},
          structuredResult: null,
        );

      case 'read_url_content':
        final url = str('Url') ?? str('url') ?? '';
        return (
          name: 'WebFetch',
          input: {'url': url},
          structuredResult: null,
        );

      case 'invoke_subagent' || 'browser_subagent':
        final desc = str('Role') ?? str('TaskName') ?? rawName;
        final subType = str('TypeName') ?? rawName;
        final prompt = str('Prompt') ?? str('Task') ?? '';
        return (
          name: 'Agent',
          input: {
            'description': desc,
            'subagent_type': subType,
            'prompt': prompt,
          },
          structuredResult: null,
        );

      default:
        return (name: rawName, input: params, structuredResult: null);
    }
  }

  static Map<String, Object?> _buildHunk(
    String oldStr,
    String newStr, {
    int startLine = 1,
  }) {
    final oldLines = oldStr.isEmpty ? const <String>[] : oldStr.split('\n');
    final newLines = newStr.isEmpty ? const <String>[] : newStr.split('\n');
    return {
      'oldStart': startLine,
      'oldLines': oldLines.length,
      'newStart': startLine,
      'newLines': newLines.length,
      'lines': [
        for (final l in oldLines) '-$l',
        for (final l in newLines) '+$l',
      ],
    };
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _interrupted = true;
    _live.remove(this);
    unawaited(_stopProcess(notifyActiveTurn: true));
    if (!_messages.isClosed) {
      _messages
        ..add(ClaudeExit.message(0, '', executable: executable))
        ..close();
    }
    if (!_exited.isCompleted) {
      _exited.complete();
    }
  }
}

/// Manages streaming events for a single user turn on [AntigravityTransport]'s
/// persistent `agy` process.
class _ActiveTurn {
  _ActiveTurn({
    required this.transport,
    required this.turnId,
    required this.onConversationBound,
  });

  final AntigravityTransport transport;
  final int turnId;
  final void Function(String convId) onConversationBound;
  final Completer<void> done = Completer<void>();

  final List<String> stderrLines = [];
  bool gotResult = false;
  bool receivedAnyEvent = false;
  bool reusedProcess = false;
  bool needsFreshRetry = false;
  bool streamedAnyResponse = false;
  String? lastToolError;

  final Map<int, bool> stepThinkingStarted = {};
  final Map<int, bool> stepThinkingStopped = {};
  final Map<int, bool> stepTextStarted = {};
  final Map<int, bool> stepTextStopped = {};
  final Map<int, bool> stepMessageStarted = {};
  final Map<int, bool> stepMessageStopped = {};
  final Map<int, StringBuffer> stepThinkingBuffer = {};
  final Map<int, StringBuffer> stepTextBuffer = {};
  final Map<int, Map<String, Object?>> stepUsage = {};
  final Map<int, bool> toolEmittedActive = {};
  final Map<int, bool> toolEmittedDone = {};
  final Map<
    int,
    ({
      String toolId,
      String rawName,
      String mappedName,
      Map<String, Object?> input,
      String output,
      Map<String, Object?>? structuredResult,
      bool isError,
    })
  >
  toolLatest = {};

  void _emitAndLog(Map<String, Object?> message, {bool persist = false}) {
    transport._emit(message);
    if (persist) {
      transport._sessionLog?.append(message);
    }
  }

  void ensureMessageStarted(int stepIndex) {
    if (stepMessageStarted[stepIndex] == true) return;
    stepMessageStarted[stepIndex] = true;
    transport._emit({
      'type': 'stream_event',
      'event': {
        'type': 'message_start',
        'message': {
          'id': 'agy-$turnId-$stepIndex',
          'model': transport._model,
          'usage': const <String, Object?>{},
        },
      },
    });
  }

  void finishStepMessage(int stepIndex) {
    if (stepMessageStarted[stepIndex] != true ||
        stepMessageStopped[stepIndex] == true) {
      return;
    }
    stepMessageStopped[stepIndex] = true;
    if (stepThinkingStarted[stepIndex] == true &&
        stepThinkingStopped[stepIndex] != true) {
      stepThinkingStopped[stepIndex] = true;
      transport._emit({
        'type': 'stream_event',
        'event': {'type': 'content_block_stop', 'index': 0},
      });
    }
    if (stepTextStarted[stepIndex] == true &&
        stepTextStopped[stepIndex] != true) {
      stepTextStopped[stepIndex] = true;
      transport._emit({
        'type': 'stream_event',
        'event': {'type': 'content_block_stop', 'index': 1},
      });
    }
    transport._emit({
      'type': 'stream_event',
      'event': {'type': 'message_stop'},
    });

    final fullThinking = stepThinkingBuffer[stepIndex]?.toString() ?? '';
    final fullText = stepTextBuffer[stepIndex]?.toString() ?? '';
    final usage = stepUsage[stepIndex];
    _emitAndLog({
      'type': 'assistant',
      'uuid': 'agy-msg-$turnId-$stepIndex',
      'message': {
        'id': 'agy-$turnId-$stepIndex',
        'model': transport._model,
        'role': 'assistant',
        'content': [
          if (fullThinking.isNotEmpty)
            {'type': 'thinking', 'thinking': fullThinking},
          if (fullText.isNotEmpty) {'type': 'text', 'text': fullText},
        ],
        'usage': ?usage,
      },
    }, persist: true);
  }

  void completeToolStep(int stepIndex) {
    if (toolEmittedDone[stepIndex] == true) return;
    final info = toolLatest[stepIndex];
    if (info == null) return;
    toolEmittedDone[stepIndex] = true;
    transport._completedToolSteps.add(stepIndex);

    _emitAndLog({
      'type': 'user',
      'uuid': 'agy-tool-res-$turnId-$stepIndex',
      'message': {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': info.toolId,
            'content': info.output,
            'is_error': info.isError,
          },
        ],
      },
      if (!info.isError && info.structuredResult != null)
        'tool_use_result': info.structuredResult,
    }, persist: true);
  }

  void settleEarlierSteps(int currentStepIndex) {
    for (final prevIdx in [...stepMessageStarted.keys]) {
      if (prevIdx < currentStepIndex) {
        finishStepMessage(prevIdx);
      }
    }
    for (final prevIdx in [...toolEmittedActive.keys]) {
      if (prevIdx < currentStepIndex && toolEmittedDone[prevIdx] != true) {
        completeToolStep(prevIdx);
      }
    }
  }

  void handleStepUpdate(Map<String, Object?> step) {
    if (step['conversation_id'] case final String convId
        when convId.isNotEmpty) {
      onConversationBound(convId);
    }
    final stepIndex = (step['step_index'] as num?)?.round() ?? 0;
    final state = step['state'] as String? ?? '';
    final stepType = step['step_type'] as String? ?? '';

    settleEarlierSteps(stepIndex);

    if (stepType == 'agent_response') {
      final thinkingDelta = step['thinking_delta'] as String? ?? '';
      final textDelta = step['text_delta'] as String? ?? '';
      final usage = transport._mapUsage(step['usage']);
      if (usage != null) {
        stepUsage[stepIndex] = usage;
      }

      if (thinkingDelta.isNotEmpty) {
        ensureMessageStarted(stepIndex);
        if (stepThinkingStarted[stepIndex] != true) {
          stepThinkingStarted[stepIndex] = true;
          stepThinkingBuffer[stepIndex] = StringBuffer();
          transport._emit({
            'type': 'stream_event',
            'event': {
              'type': 'content_block_start',
              'index': 0,
              'content_block': const {'type': 'thinking'},
            },
          });
        }
        stepThinkingBuffer[stepIndex]!.write(thinkingDelta);
        transport._emit({
          'type': 'stream_event',
          'event': {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'thinking_delta', 'thinking': thinkingDelta},
          },
        });
      }

      if (textDelta.isNotEmpty) {
        streamedAnyResponse = true;
        ensureMessageStarted(stepIndex);
        if (stepThinkingStarted[stepIndex] == true &&
            stepThinkingStopped[stepIndex] != true) {
          stepThinkingStopped[stepIndex] = true;
          transport._emit({
            'type': 'stream_event',
            'event': {'type': 'content_block_stop', 'index': 0},
          });
        }
        if (stepTextStarted[stepIndex] != true) {
          stepTextStarted[stepIndex] = true;
          stepTextBuffer[stepIndex] = StringBuffer();
          transport._emit({
            'type': 'stream_event',
            'event': {
              'type': 'content_block_start',
              'index': 1,
              'content_block': const {'type': 'text'},
            },
          });
        }
        stepTextBuffer[stepIndex]!.write(textDelta);
        transport._emit({
          'type': 'stream_event',
          'event': {
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'text_delta', 'text': textDelta},
          },
        });
      }

      if (usage != null && stepMessageStarted[stepIndex] == true) {
        transport._emit({
          'type': 'stream_event',
          'event': {'type': 'message_delta', 'usage': usage},
        });
      }

      if (state == 'DONE') {
        finishStepMessage(stepIndex);
      }
    } else if (stepType == 'tool' || stepType == 'subagent') {
      if (transport._completedToolSteps.contains(stepIndex) ||
          toolEmittedDone[stepIndex] == true) {
        return;
      }
      final toolInfo = (step['tool_info'] as Map?)?.cast<String, Object?>();
      final subagentInfo =
          (step['subagent_info'] as Map?)?.cast<String, Object?>();
      final rawName =
          (toolInfo?['name'] as String?) ??
          (step['tool_name'] as String?) ??
          (subagentInfo != null ? 'invoke_subagent' : 'tool');
      final rawParams =
          (toolInfo?['parameters'] as Map?)?.cast<String, Object?>() ??
          (subagentInfo ?? const <String, Object?>{});

      final isError = state == 'ERROR' || state == 'FAILED';
      final rawOutputStr = '${toolInfo?['output'] ?? ''}'.trim();
      final rawErrorStr =
          '${toolInfo?['error'] ?? step['error'] ?? ''}'.trim();
      final combinedRaw = isError && rawErrorStr.isNotEmpty
          ? (rawOutputStr.isNotEmpty
                ? '$rawErrorStr\n$rawOutputStr'
                : rawErrorStr)
          : rawOutputStr;
      final cleanedOutput = AntigravityTransport.cleanToolOutput(
        rawName,
        combinedRaw,
      );
      if (isError && cleanedOutput.isNotEmpty) {
        lastToolError = cleanedOutput;
      }

      final mapped = AntigravityTransport.mapTool(
        rawName,
        rawParams,
        cleanedOutput,
        defaultCwd: transport.launch.cwd,
      );
      final toolId = 'agy-tool-$turnId-$stepIndex';

      toolLatest[stepIndex] = (
        toolId: toolId,
        rawName: rawName,
        mappedName: mapped.name,
        input: mapped.input,
        output: cleanedOutput,
        structuredResult: mapped.structuredResult,
        isError: isError,
      );

      if (toolEmittedActive[stepIndex] != true) {
        toolEmittedActive[stepIndex] = true;
        _emitAndLog({
          'type': 'assistant',
          'uuid': 'agy-tool-msg-$turnId-$stepIndex',
          'message': {
            'id': 'agy-tool-msg-$turnId-$stepIndex',
            'model': transport._model,
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': toolId,
                'name': mapped.name,
                'input': mapped.input,
              },
            ],
          },
        }, persist: true);
      }

      final isBackgroundedDaemon = rawOutputStr.contains(
        'Tool is running as a background task',
      );
      if (state == 'DONE' || isError || isBackgroundedDaemon) {
        completeToolStep(stepIndex);
      }
    }
  }

  void handleLine(String line) {
    if (done.isCompleted) return;
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      stderrLines.add(trimmed);
      return;
    }
    if (decoded is! Map) return;
    final event = decoded.cast<String, Object?>();
    receivedAnyEvent = true;
    switch (event['event']) {
      case 'init':
        if (event['conversation_id'] case final String convId
            when convId.isNotEmpty) {
          onConversationBound(convId);
        }
      case 'step_update':
        if (event['step_update'] case final Map step) {
          handleStepUpdate(step.cast<String, Object?>());
        }
      case 'result':
        gotResult = true;
        for (final idx in [...stepMessageStarted.keys]) {
          finishStepMessage(idx);
        }
        for (final idx in [...toolEmittedActive.keys]) {
          completeToolStep(idx);
        }
        final result =
            (event['result'] as Map?)?.cast<String, Object?>() ?? const {};
        if (result['conversation_id'] case final String convId
            when convId.isNotEmpty) {
          onConversationBound(convId);
        }
        final status = result['status'] as String? ?? 'SUCCESS';
        final isError = status != 'SUCCESS';
        final responseText = '${result['response'] ?? ''}'.trim();
        final errorText = '${result['error'] ?? ''}'.trim();
        final durationSec = (result['duration_seconds'] as num?)?.toDouble();
        final usage = transport._mapUsage(result['usage']);

        if (!streamedAnyResponse) {
          final fallbackText = !isError && responseText.isNotEmpty
              ? responseText
              : (responseText.isEmpty && lastToolError != null
                    ? '工具执行返回错误：\n```\n$lastToolError\n```'
                    : '');
          if (fallbackText.isNotEmpty) {
            _emitAndLog({
              'type': 'assistant',
              'uuid': 'agy-final-$turnId',
              'message': {
                'id': 'agy-final-$turnId',
                'model': transport._model,
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': fallbackText},
                ],
                'usage': ?usage,
              },
            }, persist: true);
          }
        }

        transport._emit({
          'type': 'result',
          'subtype': transport._interrupted
              ? 'error_during_execution'
              : isError
              ? 'error'
              : 'success',
          'is_error': isError && !transport._interrupted,
          'result': isError
              ? (errorText.isNotEmpty
                    ? errorText
                    : responseText.isNotEmpty
                    ? responseText
                    : 'Antigravity CLI 执行出错')
              : responseText,
          if (durationSec != null)
            'duration_ms': (durationSec * 1000).round(),
          'usage': ?usage,
        });

        if (!done.isCompleted) {
          done.complete();
        }
    }
  }

  void handleStderr(String line) {
    stderrLines.add(line);
    if (stderrLines.length > 50) {
      stderrLines.removeAt(0);
    }
  }

  void handleProcessExit(int exitCode) {
    if (done.isCompleted) return;
    if (reusedProcess && !receivedAnyEvent && !transport._interrupted) {
      needsFreshRetry = true;
      done.complete();
      return;
    }
    for (final idx in [...stepMessageStarted.keys]) {
      finishStepMessage(idx);
    }
    for (final idx in [...toolEmittedActive.keys]) {
      completeToolStep(idx);
    }
    if (!gotResult) {
      final errText = stderrLines.join('\n').trim();
      transport._emit({
        'type': 'result',
        'subtype': transport._interrupted || exitCode == 0
            ? 'success'
            : 'error',
        'is_error': !transport._interrupted && exitCode != 0,
        'result': !transport._interrupted && exitCode != 0
            ? (errText.isNotEmpty
                  ? errText
                  : 'Antigravity CLI 退出（代码 $exitCode）')
            : '',
      });
    }
    done.complete();
  }
}

/// Appends Claude Code-compatible `.jsonl` lines for an Antigravity CLI
/// session so Byte's sidebar (`ClaudeSessions`), history pager, and Session
/// Replay work natively.
class _AntigravitySessionLog {
  _AntigravitySessionLog({
    required this.paths,
    required this.cwd,
    required this.sessionId,
    required this.persist,
  }) : filePath = paths.findSession(sessionId) ??
           paths.sessionFile(cwd, sessionId) {
    _loadExistingLeaf();
  }

  final AgentPaths paths;
  final String cwd;
  final String sessionId;
  final bool persist;
  final String filePath;

  String? _leafUuid;
  int _seq = 0;

  void _loadExistingLeaf() {
    final file = File(filePath);
    if (!file.existsSync()) return;
    try {
      final lines = file.readAsLinesSync();
      for (final line in lines.reversed) {
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line);
        if (decoded is Map && decoded['uuid'] is String) {
          _leafUuid = decoded['uuid'] as String;
          break;
        }
      }
    } on Object {
      // Ignore malformed lines.
    }
  }

  void append(Map<String, Object?> entry) {
    if (!persist) return;
    final uuid =
        (entry['uuid'] as String?) ??
        'agy-$sessionId-${DateTime.now().microsecondsSinceEpoch}-${++_seq}';
    final line = <String, Object?>{
      'parentUuid': _leafUuid,
      'isSidechain': false,
      'userType': 'external',
      'cwd': cwd,
      'sessionId': sessionId,
      'version': agentVersion,
      ...entry,
      if (entry['tool_use_result'] != null && entry['toolUseResult'] == null)
        'toolUseResult': entry['tool_use_result'],
      'uuid': uuid,
      'timestamp':
          entry['timestamp'] ?? DateTime.now().toUtc().toIso8601String(),
    };
    _leafUuid = uuid;
    _writeRaw(line);
  }

  void noteTitle(String title) {
    if (!persist) return;
    _writeRaw({
      'type': 'custom-title',
      'customTitle': title,
      'sessionId': sessionId,
    });
  }

  void _writeRaw(Map<String, Object?> line) {
    try {
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${jsonEncode(line)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // Ignore disk errors.
    }
  }

  /// Extracts a concise summary of recent turns when switching an existing
  /// Claude Code session to Antigravity CLI mid-conversation.
  String buildRecentContextSummary({int maxChars = 4000}) {
    final file = File(filePath);
    if (!file.existsSync()) return '';
    try {
      final snippets = <String>[];
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        final type = decoded['type'];
        final msg = decoded['message'];
        if (msg is! Map) continue;
        final content = msg['content'];
        if (type == 'user' && decoded['toolUseResult'] == null) {
          final text = _extractText(content);
          if (text.isNotEmpty && !text.startsWith('<')) {
            snippets.add('User: $text');
          }
        } else if (type == 'assistant') {
          final text = _extractText(content);
          if (text.isNotEmpty) {
            snippets.add('Assistant: $text');
          }
        }
      }
      if (snippets.isEmpty) return '';
      final joined = snippets.reversed.take(8).toList().reversed.join('\n\n');
      return joined.length > maxChars
          ? joined.substring(joined.length - maxChars)
          : joined;
    } on Object {
      return '';
    }
  }

  static String _extractText(Object? content) {
    if (content is String) return content.trim();
    if (content is List) {
      final parts = <String>[];
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          final t = '${block['text'] ?? ''}'.trim();
          if (t.isNotEmpty) parts.add(t);
        }
      }
      return parts.join('\n');
    }
    return '';
  }
}

/// Converts `~/.gemini/antigravity-cli/brain/<sessionId>/.system_generated/logs/transcript.jsonl`
/// into a Claude Code `.jsonl` session file under `~/.claude/projects/<cwd>/<sessionId>.jsonl`
/// when the `.jsonl` file does not exist yet.
///
/// Returns the `.jsonl` file path when it exists or was synthesized, or `null`
/// if neither `.jsonl` nor an Antigravity brain transcript exists.
String? syncAntigravityTranscriptIfNeeded({
  required String cwd,
  required String sessionId,
  AgentPaths? paths,
  String model = 'gemini-3.8-flash-high',
}) {
  if (sessionId.isEmpty) return null;
  final resolvedPaths = paths ?? AgentPaths.from(Platform.environment);
  final targetPath =
      resolvedPaths.findSession(sessionId) ??
      resolvedPaths.sessionFile(cwd, sessionId);
  final targetFile = File(targetPath);
  if (targetFile.existsSync() && targetFile.lengthSync() > 0) {
    return targetPath;
  }

  final brainTranscript = File(
    p.join(
      resolvedPaths.home,
      '.gemini',
      'antigravity-cli',
      'brain',
      sessionId,
      '.system_generated',
      'logs',
      'transcript.jsonl',
    ),
  );
  if (!brainTranscript.existsSync()) return null;

  List<Map<String, Object?>> steps;
  try {
    steps = [
      for (final line in brainTranscript.readAsLinesSync())
        if (line.trim().isNotEmpty)
          (jsonDecode(line) as Map).cast<String, Object?>(),
    ];
  } on Object {
    return null;
  }
  if (steps.isEmpty) return null;

  final log = _AntigravitySessionLog(
    paths: resolvedPaths,
    cwd: cwd,
    sessionId: sessionId,
    persist: true,
  );

  var seq = 0;
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final type = step['type'] as String? ?? '';
    final timestamp = step['created_at'] as String?;

    if (type == 'USER_INPUT') {
      final rawContent = '${step['content'] ?? ''}';
      final match = RegExp(
        r'<USER_REQUEST>\s*([\s\S]*?)\s*</USER_REQUEST>',
      ).firstMatch(rawContent);
      final userText = (match != null ? match.group(1)! : rawContent).trim();
      if (userText.isEmpty) continue;
      seq++;
      log.append({
        'type': 'user',
        'uuid': 'agy-import-$sessionId-u-$seq',
        'timestamp': ?timestamp,
        'message': {
          'role': 'user',
          'content': userText,
        },
      });
    } else if (type == 'PLANNER_RESPONSE') {
      final thinking = '${step['thinking'] ?? ''}'.trim();
      final text = '${step['content'] ?? ''}'.trim();
      final inputTokens = (step['input_tokens'] as num?)?.round() ?? 0;
      final outputTokens = (step['output_tokens'] as num?)?.round() ?? 0;
      final cacheRead = (step['cache_read_tokens'] as num?)?.round() ?? 0;
      final usage = (inputTokens > 0 || outputTokens > 0 || cacheRead > 0)
          ? <String, Object?>{
              'input_tokens': inputTokens,
              'output_tokens': outputTokens,
              if (cacheRead > 0) 'cache_read_input_tokens': cacheRead,
            }
          : null;

      if (thinking.isNotEmpty || text.isNotEmpty) {
        seq++;
        log.append({
          'type': 'assistant',
          'uuid': 'agy-import-$sessionId-a-$seq',
          'timestamp': ?timestamp,
          'message': {
            'id': 'agy-import-$sessionId-a-$seq',
            'model': model,
            'role': 'assistant',
            'content': [
              if (thinking.isNotEmpty)
                {'type': 'thinking', 'thinking': thinking},
              if (text.isNotEmpty) {'type': 'text', 'text': text},
            ],
            'usage': ?usage,
          },
        });
      }

      final toolCalls = step['tool_calls'];
      if (toolCalls is List && toolCalls.isNotEmpty) {
        Map<String, Object?>? nextGeneric;
        if (i + 1 < steps.length && steps[i + 1]['type'] == 'GENERIC') {
          nextGeneric = steps[i + 1];
        }
        for (final rawCall in toolCalls) {
          if (rawCall is! Map) continue;
          final rawName = '${rawCall['name'] ?? 'tool'}';
          final rawArgs =
              (rawCall['args'] as Map?)?.cast<String, Object?>() ?? const {};
          final isError = nextGeneric?['status'] == 'ERROR';
          final rawOut = '${nextGeneric?['content'] ?? ''}'.trim();
          final rawErr = '${nextGeneric?['error'] ?? ''}'.trim();
          final combinedOut = isError && rawErr.isNotEmpty ? rawErr : rawOut;
          final cleanedOut = AntigravityTransport.cleanToolOutput(
            rawName,
            combinedOut,
          );
          final mapped = AntigravityTransport.mapTool(
            rawName,
            rawArgs,
            cleanedOut,
            defaultCwd: cwd,
          );
          seq++;
          final toolId = 'agy-import-$sessionId-t-$seq';
          final resultTs =
              (nextGeneric?['created_at'] as String?) ?? timestamp;
          log.append({
            'type': 'assistant',
            'uuid': 'agy-import-$sessionId-tu-$seq',
            'timestamp': ?timestamp,
            'message': {
              'id': 'agy-import-$sessionId-tu-$seq',
              'model': model,
              'role': 'assistant',
              'content': [
                {
                  'type': 'tool_use',
                  'id': toolId,
                  'name': mapped.name,
                  'input': mapped.input,
                },
              ],
            },
          });
          log.append({
            'type': 'user',
            'uuid': 'agy-import-$sessionId-tr-$seq',
            'timestamp': ?resultTs,
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': toolId,
                  'content': cleanedOut,
                  'is_error': isError,
                },
              ],
            },
            if (!isError && mapped.structuredResult != null)
              'tool_use_result': mapped.structuredResult,
          });
        }
      }
    }
  }
  return targetFile.existsSync() ? targetPath : null;
}

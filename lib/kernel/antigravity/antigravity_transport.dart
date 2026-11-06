import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
class AntigravityTransport implements ClaudeCodeTransport {
  AntigravityTransport._({
    required this.executable,
    required this.environment,
    required this.launch,
  }) : _conversationId = launch.resume,
       _model = AntigravityModels.bareModelId(launch.model),
       _permissionMode = launch.permissionMode ?? 'default',
       _effort = launch.effort {
    _live.add(this);
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

  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final Completer<void> _exited = Completer<void>();

  String? _conversationId;
  String _model;
  String _permissionMode;
  String? _effort;
  bool _closed = false;
  Process? _activeProcess;
  bool _interrupted = false;
  int _turnCounter = 0;
  int _lastTotalTokens = 0;

  /// Queue of user turns to run sequentially.
  Future<void> _turnQueue = Future.value();

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _exited.future;

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
          'session_id': _conversationId ?? '',
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
        _activeProcess?.kill();
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

  List<String> _buildArguments() {
    final args = <String>[
      '--input-format=stream-json',
      '--output-format=stream-json',
      if (_conversationId case final id? when id.isNotEmpty)
        '--conversation=$id',
      if (_model.isNotEmpty && _model != 'default') '--model=$_model',
      if (_effort case final effort?
          when const {'low', 'medium', 'high', 'xhigh', 'max'}.contains(effort))
        '--effort=$effort',
      switch (_permissionMode) {
        'plan' => '--mode=plan',
        'bypassPermissions' || 'dontAsk' => '--dangerously-skip-permissions',
        'auto' => '--mode=auto',
        _ => '--mode=accept-edits',
      },
      for (final dir in launch.directories) '--add-dir=$dir',
      '-p=',
    ];
    return args;
  }

  Future<void> _runUserTurn(Map<String, Object?> userMessage) async {
    if (_closed) return;
    final prompt = await _extractPrompt(userMessage);
    if (prompt.trim().isEmpty) return;

    if (prompt.trim() == '/clear') {
      _conversationId = null;
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

    final turnId = ++_turnCounter;
    _interrupted = false;

    _emit({
      'type': 'system',
      'subtype': 'session_state_changed',
      'state': 'working',
    });

    final args = _buildArguments();
    Process process;
    try {
      process = await Process.start(
        executable,
        args,
        workingDirectory: launch.cwd,
        environment: environment,
      );
    } on ProcessException catch (error) {
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
    }

    _activeProcess = process;
    final stderrLines = <String>[];
    var gotResult = false;
    var streamedAnyResponse = false;

    // Per-step state within this turn.
    final stepThinkingStarted = <int, bool>{};
    final stepThinkingStopped = <int, bool>{};
    final stepTextStarted = <int, bool>{};
    final stepTextStopped = <int, bool>{};
    final stepMessageStarted = <int, bool>{};
    final stepMessageStopped = <int, bool>{};
    final stepThinkingBuffer = <int, StringBuffer>{};
    final stepTextBuffer = <int, StringBuffer>{};
    final stepUsage = <int, Map<String, Object?>>{};
    final toolEmittedActive = <int, bool>{};
    final toolEmittedDone = <int, bool>{};

    void ensureMessageStarted(int stepIndex) {
      if (stepMessageStarted[stepIndex] == true) return;
      stepMessageStarted[stepIndex] = true;
      _emit({
        'type': 'stream_event',
        'event': {
          'type': 'message_start',
          'message': {
            'id': 'agy-$turnId-$stepIndex',
            'model': _model,
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
        _emit({
          'type': 'stream_event',
          'event': {'type': 'content_block_stop', 'index': 0},
        });
      }
      if (stepTextStarted[stepIndex] == true &&
          stepTextStopped[stepIndex] != true) {
        stepTextStopped[stepIndex] = true;
        _emit({
          'type': 'stream_event',
          'event': {'type': 'content_block_stop', 'index': 1},
        });
      }
      _emit({
        'type': 'stream_event',
        'event': {'type': 'message_stop'},
      });

      final fullThinking = stepThinkingBuffer[stepIndex]?.toString() ?? '';
      final fullText = stepTextBuffer[stepIndex]?.toString() ?? '';
      final usage = stepUsage[stepIndex];
      _emit({
        'type': 'assistant',
        'uuid': 'agy-msg-$turnId-$stepIndex',
        'message': {
          'id': 'agy-$turnId-$stepIndex',
          'model': _model,
          'role': 'assistant',
          'content': [
            if (fullThinking.isNotEmpty)
              {'type': 'thinking', 'thinking': fullThinking},
            if (fullText.isNotEmpty) {'type': 'text', 'text': fullText},
          ],
          'usage': ?usage,
        },
      });
    }

    Map<String, Object?>? mapUsage(Object? rawUsage) {
      if (rawUsage is! Map) return null;
      final inputTokens = (rawUsage['input_tokens'] as num?)?.round() ?? 0;
      final outputTokens = (rawUsage['output_tokens'] as num?)?.round() ?? 0;
      final cacheRead = (rawUsage['cache_read_tokens'] as num?)?.round() ?? 0;
      final thinkingTokens = (rawUsage['thinking_tokens'] as num?)?.round();
      final totalTokens = (rawUsage['total_tokens'] as num?)?.round();
      if (totalTokens != null && totalTokens > 0) {
        _lastTotalTokens = totalTokens + cacheRead;
      }
      return {
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        if (cacheRead > 0) 'cache_read_input_tokens': cacheRead,
        if (thinkingTokens != null)
          'output_tokens_details': {'thinking_tokens': thinkingTokens},
      };
    }

    void handleStepUpdate(Map<String, Object?> step) {
      if (step['conversation_id'] case final String convId
          when convId.isNotEmpty && _conversationId != convId) {
        _conversationId = convId;
        _emit({
          'type': 'system',
          'subtype': 'init',
          'session_id': convId,
          'model': _model,
          'permissionMode': _permissionMode,
          if (_effort != null) 'effort': _effort,
        });
      }
      final stepIndex = (step['step_index'] as num?)?.round() ?? 0;
      final state = step['state'] as String? ?? '';
      final stepType = step['step_type'] as String? ?? '';

      if (stepType == 'agent_response') {
        final thinkingDelta = step['thinking_delta'] as String? ?? '';
        final textDelta = step['text_delta'] as String? ?? '';
        final usage = mapUsage(step['usage']);
        if (usage != null) {
          stepUsage[stepIndex] = usage;
        }

        if (thinkingDelta.isNotEmpty) {
          ensureMessageStarted(stepIndex);
          if (stepThinkingStarted[stepIndex] != true) {
            stepThinkingStarted[stepIndex] = true;
            stepThinkingBuffer[stepIndex] = StringBuffer();
            _emit({
              'type': 'stream_event',
              'event': {
                'type': 'content_block_start',
                'index': 0,
                'content_block': const {'type': 'thinking'},
              },
            });
          }
          stepThinkingBuffer[stepIndex]!.write(thinkingDelta);
          _emit({
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
            _emit({
              'type': 'stream_event',
              'event': {'type': 'content_block_stop', 'index': 0},
            });
          }
          if (stepTextStarted[stepIndex] != true) {
            stepTextStarted[stepIndex] = true;
            stepTextBuffer[stepIndex] = StringBuffer();
            _emit({
              'type': 'stream_event',
              'event': {
                'type': 'content_block_start',
                'index': 1,
                'content_block': const {'type': 'text'},
              },
            });
          }
          stepTextBuffer[stepIndex]!.write(textDelta);
          _emit({
            'type': 'stream_event',
            'event': {
              'type': 'content_block_delta',
              'index': 1,
              'delta': {'type': 'text_delta', 'text': textDelta},
            },
          });
        }

        if (usage != null && stepMessageStarted[stepIndex] == true) {
          _emit({
            'type': 'stream_event',
            'event': {'type': 'message_delta', 'usage': usage},
          });
        }

        if (state == 'DONE') {
          finishStepMessage(stepIndex);
        }
      } else if (stepType == 'tool') {
        if (toolEmittedDone[stepIndex] == true) return;
        final toolInfo = (step['tool_info'] as Map?)?.cast<String, Object?>();
        final rawName =
            (toolInfo?['name'] as String?) ??
            (step['tool_name'] as String?) ??
            'tool';
        final rawParams =
            (toolInfo?['parameters'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
        final output = '${toolInfo?['output'] ?? ''}'.trim();
        final mapped = _mapTool(rawName, rawParams, output);
        final toolId = 'agy-tool-$turnId-$stepIndex';

        if (toolEmittedActive[stepIndex] != true || state == 'DONE') {
          toolEmittedActive[stepIndex] = true;
          _emit({
            'type': 'assistant',
            'uuid': 'agy-tool-msg-$turnId-$stepIndex',
            'message': {
              'id': 'agy-tool-msg-$turnId-$stepIndex',
              'model': _model,
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
        }

        if (state == 'DONE' || state == 'ERROR' || state == 'FAILED') {
          toolEmittedDone[stepIndex] = true;
          final isError = state == 'ERROR' || state == 'FAILED';
          _emit({
            'type': 'user',
            'uuid': 'agy-tool-res-$turnId-$stepIndex',
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': toolId,
                  'content': output,
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

    void handleLine(String line) {
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
      switch (event['event']) {
        case 'init':
          if (event['conversation_id'] case final String convId
              when convId.isNotEmpty) {
            _conversationId = convId;
          }
          _emit({
            'type': 'system',
            'subtype': 'init',
            'session_id': _conversationId ?? '',
            'model': _model,
            'permissionMode': _permissionMode,
            if (_effort != null) 'effort': _effort,
          });
        case 'step_update':
          if (event['step_update'] case final Map step) {
            handleStepUpdate(step.cast<String, Object?>());
          }
        case 'result':
          gotResult = true;
          for (final idx in [...stepMessageStarted.keys]) {
            finishStepMessage(idx);
          }
          final result =
              (event['result'] as Map?)?.cast<String, Object?>() ?? const {};
          if (result['conversation_id'] case final String convId
              when convId.isNotEmpty) {
            _conversationId = convId;
          }
          final status = result['status'] as String? ?? 'SUCCESS';
          final isError = status != 'SUCCESS';
          final responseText = '${result['response'] ?? ''}'.trim();
          final errorText = '${result['error'] ?? ''}'.trim();
          final durationSec = (result['duration_seconds'] as num?)?.toDouble();
          final usage = mapUsage(result['usage']);

          if (!streamedAnyResponse && !isError && responseText.isNotEmpty) {
            _emit({
              'type': 'assistant',
              'uuid': 'agy-final-$turnId',
              'message': {
                'id': 'agy-final-$turnId',
                'model': _model,
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': responseText},
                ],
                'usage': ?usage,
              },
            });
          }

          _emit({
            'type': 'result',
            'subtype': _interrupted
                ? 'error_during_execution'
                : isError
                ? 'error'
                : 'success',
            'is_error': isError && !_interrupted,
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
      }
    }

    final stdoutSub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(handleLine, onError: (Object e) => stderrLines.add('$e'));
    final stderrSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(stderrLines.add, onError: (Object e) => stderrLines.add('$e'));

    try {
      process.stdin.writeln(
        jsonEncode({
          'event': 'user',
          'message': {'role': 'user', 'content': prompt},
        }),
      );
      await process.stdin.close();
    } on Object {
      // Stdin closed early.
    }

    final exitCode = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();
    if (identical(_activeProcess, process)) {
      _activeProcess = null;
    }

    for (final idx in [...stepMessageStarted.keys]) {
      finishStepMessage(idx);
    }

    if (!gotResult) {
      final errText = stderrLines.join('\n').trim();
      _emit({
        'type': 'result',
        'subtype': _interrupted || exitCode == 0 ? 'success' : 'error',
        'is_error': !_interrupted && exitCode != 0,
        'result': !_interrupted && exitCode != 0
            ? (errText.isNotEmpty
                  ? errText
                  : 'Antigravity CLI 退出（代码 $exitCode）')
            : '',
      });
    }

    _emit({
      'type': 'system',
      'subtype': 'session_state_changed',
      'state': 'idle',
    });
  }

  /// Maps an Antigravity CLI tool call (`read_file`, `edit_file`, `write_file`,
  /// `run_command`, `grep_search`, `find_by_name`, etc.) to Claude Code's
  /// tool schema so `ClaudeTranslator` renders rich native cards and diffs.
  ({
    String name,
    Map<String, Object?> input,
    Map<String, Object?>? structuredResult,
  })
  _mapTool(String rawName, Map<String, Object?> params, String output) {
    String? str(String key) => switch (params[key]) {
      final String s when s.isNotEmpty => s,
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
        final start = (params['StartLine'] as num?)?.round();
        final end = (params['EndLine'] as num?)?.round();
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
              edits.add({'old_string': oldStr, 'new_string': newStr});
              hunks.add(
                _buildHunk(
                  oldStr,
                  newStr,
                  startLine: (rawChunk['StartLine'] as num?)?.round() ?? 1,
                ),
              );
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
            launch.cwd;
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
    _activeProcess?.kill();
    _activeProcess = null;
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

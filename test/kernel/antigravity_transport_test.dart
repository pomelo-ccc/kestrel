import 'dart:io';

import 'package:bao_remote/local.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/antigravity/antigravity_transport.dart';

void main() {
  group('AntigravityTransport tool mapping & normalization', () {
    test('normalizeToolParams decodes JSON-encoded parameter values', () {
      final raw = <String, Object?>{
        'Path': '"/Users/pomelo/work/package.json"',
        'StartLine': '1',
        'EndLine': '80',
        'IsDaemon': 'true',
        'PlainString': 'unquoted-value',
      };
      final normalized = AntigravityTransport.normalizeToolParams(raw);
      expect(normalized['Path'], '/Users/pomelo/work/package.json');
      expect(normalized['StartLine'], 1);
      expect(normalized['EndLine'], 80);
      expect(normalized['IsDaemon'], true);
      expect(normalized['PlainString'], 'unquoted-value');
    });

    test('cleanToolOutput strips Created At / Completed At headers', () {
      const rawRead =
          'Created At: 2026-11-07T08:40:27+08:00\n'
          'Completed At: 2026-11-07T08:40:27+08:00\n'
          'Showing lines 1-3 of 3\n'
          '1: {\n2:   "name": "dpp-doc"\n3: }';
      expect(
        AntigravityTransport.cleanToolOutput('read_file', rawRead),
        'Showing lines 1-3 of 3\n1: {\n2:   "name": "dpp-doc"\n3: }',
      );

      const rawBash =
          'Created At: 2026-11-07T08:40:27+08:00\n'
          'Completed At: 2026-11-07T08:40:28+08:00\n'
          'Command exited with code 0.\n\n'
          'Command output:\n'
          'HTTP/1.1 200 OK';
      expect(
        AntigravityTransport.cleanToolOutput('run_command', rawBash),
        'HTTP/1.1 200 OK',
      );
    });

    test('mapTool translates read_file, edit_file, and run_command', () {
      final readMapped = AntigravityTransport.mapTool(
        'read_file',
        {
          'Path': '"/Users/pomelo/work/package.json"',
          'StartLine': '10',
          'EndLine': '29',
        },
        '10: line',
      );
      expect(readMapped.name, 'Read');
      expect(readMapped.input, {
        'file_path': '/Users/pomelo/work/package.json',
        'offset': 10,
        'limit': 20,
      });

      final editMapped = AntigravityTransport.mapTool(
        'edit_file',
        {
          'Path': '"/Users/pomelo/work/README.md"',
          'Target': '"old line"',
          'Replacement': '"new line"',
        },
        'Made 1 replacement',
      );
      expect(editMapped.name, 'Edit');
      expect(editMapped.input['file_path'], '/Users/pomelo/work/README.md');
      expect(editMapped.input['old_string'], 'old line');
      expect(editMapped.input['new_string'], 'new line');
      expect(editMapped.structuredResult, isNotNull);

      final bashMapped = AntigravityTransport.mapTool(
        'run_command',
        {
          'CommandLine': '"pnpm run dev:docs"',
          'toolSummary': '"Start docs server"',
        },
        'Server listening on 5173',
      );
      expect(bashMapped.name, 'Bash');
      expect(bashMapped.input['command'], 'pnpm run dev:docs');
      expect(bashMapped.input['description'], 'Start docs server');
    });

    test('syncAntigravityTranscriptIfNeeded backfills existing sessions', () async {
      const cwd = '/Users/pomelo/work/projects/company/docs/dpp-doc';
      for (final sessionId in const [
        'd0abfe8c-d16c-4e58-963b-a259aad1f8c9',
        '0cc8346d-5746-4f5a-8f25-d2faa4cbe083',
      ]) {
        final path = syncAntigravityTranscriptIfNeeded(
          cwd: cwd,
          sessionId: sessionId,
        );
        if (path != null) {
          expect(File(path).existsSync(), isTrue);
          final records = await ClaudeSessions.read(path);
          expect(records, isNotEmpty);
        }
      }
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final sw = Stopwatch()..start();
  final repo = Directory.current.path;
  final sdkRootResult = await Process.run('xcrun', [
    '--sdk',
    'macosx',
    '--show-sdk-path',
  ]);
  final sdkRoot = (sdkRootResult.stdout as String).trim();

  // 1. Assemble updated kernel_blob.bin & flutter_assets
  final assemble = await Process.run('/Users/pomelo/flutter/bin/flutter', [
    'assemble',
    '--no-version-check',
    '--output=build/macos/Build/Products/Debug/',
    '-dTargetPlatform=darwin',
    '-dTargetFile=lib/main.dart',
    '-dBuildMode=debug',
    '-dConfiguration=Debug',
    '-dDarwinArchs=arm64',
    '-dSdkRoot=$sdkRoot',
    '-dSplitDebugInfo=',
    '-dDartObfuscation=false',
    '-dTreeShakeIcons=false',
    '-dTrackWidgetCreation=true',
    '-dSrcRoot=$repo/macos',
    '-dXcodeBuildScript=prepare',
    'debug_macos_bundle_flutter_assets',
  ]);
  if (assemble.exitCode != 0) {
    stderr.writeln(assemble.stderr);
    exit(assemble.exitCode);
  }

  final srcKernel = File(
    '$repo/build/macos/Build/Products/Debug/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin',
  );
  final dstKernel = File(
    '$repo/build/macos/Build/Products/Debug/Byte.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin',
  );
  await srcKernel.copy(dstKernel.path);

  // 2. Connect to running Debug Byte.app VM Service and reloadSources + reassemble
  final logFile = File('/tmp/byte_debug.log');
  if (!logFile.existsSync()) {
    stderr.writeln('No /tmp/byte_debug.log found.');
    exit(1);
  }
  final log = logFile.readAsStringSync();
  final matches = RegExp(r'http://127\.0\.0\.1:\d+/[^/\s]+/').allMatches(log);
  if (matches.isEmpty) {
    stderr.writeln('Could not find Dart VM Service URL in /tmp/byte_debug.log');
    exit(1);
  }
  final httpUri = Uri.parse(matches.last.group(0)!);
  final wsUri = httpUri.replace(scheme: 'ws', path: '${httpUri.path}ws');

  final ws = await WebSocket.connect(wsUri.toString());
  int nextId = 1;
  final pending = <String, Completer<Map<String, dynamic>>>{};
  ws.listen((data) {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    final id = msg['id']?.toString();
    if (id != null && pending.containsKey(id)) {
      pending.remove(id)!.complete(msg);
    }
  });

  Future<Map<String, dynamic>> rpc(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    final id = '${nextId++}';
    final c = Completer<Map<String, dynamic>>();
    pending[id] = c;
    ws.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': ?params,
      }),
    );
    return c.future;
  }

  final vmResp = await rpc('getVM');
  final isolates = (vmResp['result']['isolates'] as List)
      .cast<Map<String, dynamic>>();
  final mainIsolate = isolates.firstWhere(
    (iso) => (iso['name'] as String).contains('main'),
    orElse: () => isolates.first,
  );
  final isolateId = mainIsolate['id'] as String;

  final reloadResp = await rpc('reloadSources', {
    'isolateId': isolateId,
    'rootLibUri': dstKernel.uri.toString(),
  });
  await rpc('ext.flutter.reassemble', {'isolateId': isolateId});
  await ws.close();

  sw.stop();
  stdout.writeln(
    'Hot reload succeeded in ${sw.elapsedMilliseconds}ms: ${reloadResp['result']['success']}',
  );
}

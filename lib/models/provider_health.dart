import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../chat/chat_models.dart';
import '../chat/chat_session.dart';
import '../kernel/agent_kernel.dart';
import '../kernel/kernel_types.dart';
import 'model_provider.dart';
import 'model_providers.dart';

enum ProviderPingStatus { unknown, checking, healthy, slow, offline }

class ProviderPing {
  const ProviderPing({
    this.status = ProviderPingStatus.unknown,
    this.latencyMs,
    this.checkedAt,
    this.error,
  });

  final ProviderPingStatus status;
  final int? latencyMs;
  final DateTime? checkedAt;
  final String? error;

  Color get color => switch (status) {
    ProviderPingStatus.healthy => const Color(0xFF2EAD67),
    ProviderPingStatus.slow => const Color(0xFFE5A000),
    ProviderPingStatus.offline => const Color(0xFFE05252),
    ProviderPingStatus.checking => const Color(0xFF3B82F6),
    ProviderPingStatus.unknown => const Color(0xFF8C8C8C),
  };

  String get shortLabel => switch (status) {
    ProviderPingStatus.healthy ||
    ProviderPingStatus.slow when latencyMs != null => '${latencyMs}ms',
    ProviderPingStatus.offline => '离线',
    ProviderPingStatus.checking => '测速…',
    _ => '',
  };
}

/// Real-time latency monitor for configured [ModelProviders] plus live
/// streaming speed (`tok/s`) and daily token telemetry.
class ProviderHealthMonitor extends ChangeNotifier {
  ProviderHealthMonitor._();

  static final ProviderHealthMonitor instance = ProviderHealthMonitor._();

  final Map<String, ProviderPing> _pings = {};
  bool _started = false;
  Timer? _timer;

  static bool get _isTest => Platform.environment.containsKey('FLUTTER_TEST');

  ProviderPing pingOf(String? providerId) {
    if (providerId == null || providerId.isEmpty) return const ProviderPing();
    return _pings[providerId] ?? const ProviderPing();
  }

  ProviderPing pingForModel(String? modelId) {
    final ref = parseModelRef(modelId);
    if (ref == null) return const ProviderPing();
    return pingOf(ref.provider);
  }

  void ensureStarted() {
    if (_started || _isTest) return;
    _started = true;
    ModelProviders.current.addListener(_onProvidersChanged);
    unawaited(pingAll());
    _timer = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(pingAll());
    });
  }

  void _onProvidersChanged() {
    if (!_isTest) unawaited(pingAll());
  }

  Future<void> pingAll({bool force = false}) async {
    if (_isTest) return;
    final providers = ModelProviders.current.enabled;
    await Future.wait([
      for (final provider in providers) pingProvider(provider, force: force),
    ]);
  }

  Future<ProviderPing> pingProvider(
    ModelProvider provider, {
    bool force = false,
  }) async {
    if (_isTest) return const ProviderPing();
    final existing = _pings[provider.id];
    if (!force &&
        existing != null &&
        existing.checkedAt != null &&
        DateTime.now().difference(existing.checkedAt!) <
            const Duration(seconds: 15)) {
      return existing;
    }
    final rawUrl = (provider.endpointUrl?.trim().isNotEmpty ?? false)
        ? provider.endpointUrl!.trim()
        : provider.baseUrl.trim();
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return const ProviderPing();
    }
    _pings[provider.id] = ProviderPing(
      status: ProviderPingStatus.checking,
      latencyMs: existing?.latencyMs,
      checkedAt: existing?.checkedAt,
    );
    notifyListeners();

    final sw = Stopwatch()..start();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = const Duration(seconds: 2);
    try {
      final probeUri = uri.replace(
        path: uri.path.isEmpty ? '/' : uri.path,
        queryParameters: null,
      );
      final req = await client
          .openUrl('HEAD', probeUri)
          .timeout(const Duration(seconds: 4));
      req.followRedirects = false;
      final res = await req.close().timeout(const Duration(seconds: 4));
      await res.drain<void>().timeout(const Duration(seconds: 2));
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      // Even 401/404/405 from an API gateway proves the TLS endpoint is reachable;
      // 502/503/504/524 indicates upstream gateway trouble.
      final badGateway = res.statusCode >= 502 && res.statusCode <= 599;
      final status = badGateway
          ? ProviderPingStatus.offline
          : (ms < 500 ? ProviderPingStatus.healthy : ProviderPingStatus.slow);
      final ping = ProviderPing(
        status: status,
        latencyMs: ms,
        checkedAt: DateTime.now(),
        error: badGateway ? 'HTTP ${res.statusCode}' : null,
      );
      _pings[provider.id] = ping;
      notifyListeners();
      return ping;
    } on Object catch (e) {
      sw.stop();
      final ping = ProviderPing(
        status: ProviderPingStatus.offline,
        checkedAt: DateTime.now(),
        error: '$e',
      );
      _pings[provider.id] = ping;
      notifyListeners();
      return ping;
    } finally {
      client.close(force: true);
    }
  }

  /// Marks [providerId] as offline when a live request fails with a gateway or
  /// network error.
  void reportFailure(String? modelId, String errorText) {
    final ref = parseModelRef(modelId);
    if (ref == null) return;
    _pings[ref.provider] = ProviderPing(
      status: ProviderPingStatus.offline,
      checkedAt: DateTime.now(),
      error: errorText,
    );
    notifyListeners();
  }

  /// Candidate backup models on other enabled providers (or other models on
  /// the same provider), ordered with healthy/fastest providers first.
  List<
    ({
      KernelOption option,
      String providerId,
      String providerName,
      ProviderPing ping,
    })
  >
  backupCandidatesFor(ChatSession session) {
    final models = session.models;
    if (models == null) return const [];
    final currentId = models.selected.id;
    final currentRef = parseModelRef(currentId);
    final providers = ModelProviders.current;
    final candidates =
        <
          ({
            KernelOption option,
            String providerId,
            String providerName,
            ProviderPing ping,
          })
        >[];
    final seenProviders = <String>{};
    for (final option in models.options) {
      if (option.id == currentId) continue;
      final ref = parseModelRef(option.id);
      if (ref == null) continue;
      // Prefer one primary candidate per alternate provider first.
      if (ref.provider == currentRef?.provider) continue;
      if (!seenProviders.add(ref.provider)) continue;
      final provider = providers.provider(ref.provider);
      if (provider == null || !provider.enabled) continue;
      candidates.add((
        option: option,
        providerId: provider.id,
        providerName: provider.name,
        ping: pingOf(provider.id),
      ));
    }
    candidates.sort((a, b) {
      final aHealthy = a.ping.status == ProviderPingStatus.healthy ? 0 : 1;
      final bHealthy = b.ping.status == ProviderPingStatus.healthy ? 0 : 1;
      if (aHealthy != bHealthy) return aHealthy.compareTo(bHealthy);
      final aMs = a.ping.latencyMs ?? 99999;
      final bMs = b.ping.latencyMs ?? 99999;
      return aMs.compareTo(bMs);
    });
    return candidates;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Tracks live streaming speed (`tok/s`) and cumulative session/daily tokens
/// for a [ChatSession].
class SessionSpeedTracker extends ChangeNotifier {
  SessionSpeedTracker(this.session) {
    session.addListener(_onSessionChanged);
  }

  final ChatSession session;

  DateTime? _turnStart;
  DateTime? _firstTokenAt;
  int _baselineChars = 0;
  double _tokensPerSec = 0;
  double _lastTurnTokensPerSec = 0;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;

  static int todayEstimatedTokens = 0;
  static final Map<String, int> todayProviderTokens = {};

  double get tokensPerSec =>
      session.isStreaming ? _tokensPerSec : _lastTurnTokensPerSec;
  Duration get elapsed => _elapsed;

  int _countAssistantChars() {
    var chars = 0;
    for (var i = 0; i < session.itemCount; i++) {
      switch (session.itemAt(i)) {
        case AssistantTextItem(:final text):
          chars += text.length;
        case ThinkingItem(:final text):
          chars += text.length;
        default:
          break;
      }
    }
    return chars;
  }

  void _onSessionChanged() {
    final streaming = session.isStreaming;
    final totalChars = _countAssistantChars();
    if (streaming) {
      if (_turnStart == null) {
        _turnStart = DateTime.now();
        _firstTokenAt = null;
        _baselineChars = totalChars;
        _tokensPerSec = 0;
        _elapsed = Duration.zero;
        if (!ProviderHealthMonitor._isTest) {
          _ticker ??= Timer.periodic(
            const Duration(milliseconds: 500),
            (_) => _updateMetrics(_countAssistantChars()),
          );
        }
      }
      _updateMetrics(totalChars);
    } else if (_turnStart != null) {
      _updateMetrics(totalChars);
      if (_tokensPerSec > 0) _lastTurnTokensPerSec = _tokensPerSec;
      final generatedChars = (totalChars - _baselineChars).clamp(0, 10000000);
      final estTokens = (generatedChars / 2.6).round();
      if (estTokens > 0) {
        todayEstimatedTokens += estTokens;
        final modelId = session.selected(KernelChoiceKind.model);
        final providerId = parseModelRef(modelId)?.provider ?? 'builtin';
        todayProviderTokens[providerId] =
            (todayProviderTokens[providerId] ?? 0) + estTokens;
      }
      _turnStart = null;
      _firstTokenAt = null;
      _ticker?.cancel();
      _ticker = null;
      notifyListeners();
    }
  }

  void _updateMetrics(int totalChars) {
    final start = _turnStart;
    if (start == null) return;
    final now = DateTime.now();
    _elapsed = now.difference(start);
    final deltaChars = totalChars - _baselineChars;
    if (deltaChars > 0) {
      _firstTokenAt ??= now;
      final activeMs = now
          .difference(_firstTokenAt!)
          .inMilliseconds
          .clamp(150, 3600000);
      final estTokens = deltaChars / 2.6;
      _tokensPerSec = estTokens / (activeMs / 1000.0);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    session.removeListener(_onSessionChanged);
    super.dispose();
  }
}

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

void main() {
  test(
    'resuming a session without an explicit session model restores the latest '
    'assistant model from transcript history instead of global fallback',
    () async {
      final providers = ModelProviders.memory(
        providers: const [
          ModelProvider(
            id: 'acme',
            name: 'Acme',
            baseUrl: 'https://api.acme.example',
            models: [
              ProviderModel(
                id: 'acme-fast',
                efforts: ['low', 'medium', 'high'],
                contextWindow: 200000,
                contexts: [200000, 512000],
              ),
              ProviderModel(
                id: 'acme-pro',
                efforts: ['low', 'medium', 'high', 'xhigh'],
                contextWindow: 512000,
                contexts: [200000, 512000],
              ),
            ],
          ),
        ],
      );

      final session = SessionRecord(
        id: 'sess-acme-pro-1',
        title: 'Test Acme Pro Session',
        updatedAt: DateTime(2026, 11, 18),
        cwd: '/tmp/proj',
      );

      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        KernelContext(
          cwd: '/tmp/proj',
          resume: session,
          settings: const {
            'model': '@acme/acme-fast',
            'effort@@acme/acme-pro': 'xhigh',
            'context@@acme/acme-pro': '512000',
          },
        ),
        start: (_) async => FakeCli(),
        providers: providers,
        readHistory: (_) async => const [
          {
            'type': 'assistant',
            'uuid': 'asst-1',
            'message': {
              'role': 'assistant',
              'model': 'acme-pro',
              'content': [
                {'type': 'text', 'text': 'actual turn'},
              ],
            },
          },
        ],
      );
      addTearDown(kernel.dispose);

      await pumpEventQueue();
      expect(kernel.loadingHistory, isFalse);
      expect(kernel.model.selected, '@acme/acme-pro');
      expect(kernel.effort.selected, 'xhigh');
      expect(kernel.contextSize.selected, '512000');
    },
  );
}

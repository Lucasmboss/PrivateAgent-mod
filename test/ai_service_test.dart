import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/ai_service.dart';

void main() {
  test('recognizes only the NVIDIA hosted API URL', () {
    expect(
      AiService.isNvidiaBaseUrl('https://integrate.api.nvidia.com/v1'),
      isTrue,
    );
    expect(AiService.isNvidiaBaseUrl('https://api.deepseek.com'), isFalse);
  });

  test('NVIDIA model picker keeps only verified free chat models', () {
    final models = AiService.filterNvidiaFreeModels([
      'paid/partner-model',
      'nvidia/nemotron-3-super-120b-a12b',
      'nvidia/embed-qa-4',
      'openai/gpt-oss-20b',
    ]);

    expect(models, ['nvidia/nemotron-3-super-120b-a12b', 'openai/gpt-oss-20b']);
  });

  test('GLM is the default NVIDIA model', () {
    expect(AiService.nvidiaDefaultModel, 'z-ai/glm-5.2');
    expect(AiService.nvidiaFreeChatModels.first, 'z-ai/glm-5.2');
  });

  test('recovers an execute_task with a top-level goal and trailing response', () {
    const goal = 'Check the available network settings on this device.';
    final action = AiService().parseAction(
      '{"action":"execute_task","goal":"$goal"}, '
      '"response":"I will check what is available."}',
    );

    expect(action?.action, 'execute_task');
    expect(action?.params['goal'], goal);
  });

  test('preserves standard nested action parameters', () {
    final action = AiService().parseAction(
      '{"action":"open_app","params":{"app_name":"Settings"},'
      '"response":"Opening Settings."}',
    );

    expect(action?.action, 'open_app');
    expect(action?.params, {'app_name': 'Settings'});
    expect(action?.response, 'Opening Settings.');
  });
}

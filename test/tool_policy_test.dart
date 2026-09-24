import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/tool_policy.dart';
import 'package:private_agent/services/tool_registry.dart';

void main() {
  const registry = ToolRegistry();
  const policy = ToolPolicy();

  test('validated tool calls execute autonomously by default', () async {
    final values = <String, dynamic>{
      'url': 'https://example.com',
      'method': 'POST',
      'path': 'a',
      'content': '',
      'query': 'a',
      'contact_name': 'a',
      'phone_number': '123',
      'message': 'a',
      'to': 'a',
      'subject': '',
      'body': '',
      'app_name': 'a',
      'package_name': 'a',
      'hour': 1,
      'minute': 1,
      'label': '',
      'seconds': 1,
      'level': 1,
      'command': 'echo harmless',
      'text': 'a',
      'field_hint': 'a',
      'x': 1,
      'y': 1,
      'startX': 1,
      'startY': 1,
      'endX': 1,
      'endY': 1,
      'duration': 1,
      'direction': 'down',
      'milliseconds': 1,
      'goal': 'a',
      'resume_task_id': 'a',
      'question': 'a',
      'blocker_type': 'sign_in',
      'attempted_strategies': ['open_app'],
      'remaining_strategies': <String>[],
      'subtasks': [
        {
          'id': 'one',
          'objective': 'Read',
          'criteria': ['Read'],
          'dependencies': <String>[],
        },
      ],
      'evidence': <String, dynamic>{},
    };
    for (final definition in ToolRegistry.definitions) {
      final params = {
        for (final key in definition.schema.keys)
          if (key != 'headers')
            key: key == 'evidence' && definition.name == 'ask_user'
                ? 'Sign in to continue'
                : values[key],
      };
      for (final name in [definition.name, ...definition.aliases]) {
        final call = registry.validate(' ${name.toUpperCase()} ', params);
        expect(call.name, definition.name);
        expect(
          (await policy.authorize(call)).allowed,
          isTrue,
          reason: name,
        );
      }
    }
  });

  test('supported HTTP methods are authorized without a host veto', () async {
    for (final method in [
      'GET',
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
    ]) {
      final call = registry.validate('web_request', {
        'url': 'https://example.com',
        'method': ' ${method.toLowerCase()} ',
      });
      expect(
        (await policy.authorize(call)).allowed,
        isTrue,
      );
    }
  });

  test(
    'an explicit host veto remains fail-closed and secret-free',
    () async {
      final call = registry.validate('run_adb_command', {
        'command': 'token=super-secret delete approved yes',
      });
      expect((await policy.authorize(call)).allowed, isTrue);
      expect(
        (await policy.authorize(call, onApproval: (_) async => false)).allowed,
        isFalse,
      );
      expect(
        (await policy.authorize(
          call,
          onApproval: (_) async => throw StateError('secret'),
        )).allowed,
        isFalse,
      );
      expect(
        (await policy.authorize(
          call,
          onApproval: (request) async {
            expect(request.summary, isNot(contains('super-secret')));
            expect(request.toolName, 'run_adb_command');
            expect(request.risk, ToolRisk.privileged);
            return true;
          },
        )).allowed,
        isTrue,
      );
      expect(
        ToolPolicy.sanitizedEvidence(
          call,
          ToolResultClassification.unknown,
        ).toString(),
        isNot(contains('super-secret')),
      );
    },
  );

  test('schema rejects unknown, missing, wrong types and unknown fields', () {
    for (final entry in <String, Map<String, dynamic>>{
      'unknown': {},
      'write_file': {'path': 'a'},
      'click_at': {'x': '1', 'y': 2},
      'make_call': {},
      'send_sms': {'phone_number': '1'},
      'read_file': {'path': 'a', 'approved': true},
      'web_request': {
        'url': 'https://example.com',
        'headers': {'a': 1},
      },
      'set_alarm': {'hour': 99, 'minute': 0},
    }.entries) {
      expect(
        () => registry.validate(entry.key, entry.value),
        throwsA(isA<ToolValidationException>()),
      );
    }
    expect(
      () => registry.validate('web_request', {
        'url': 'https://example.com',
        'method': 'TRACE',
      }),
      throwsA(isA<ToolValidationException>()),
    );
  });

  test('approval snapshot cannot be changed after validation', () {
    final headers = {'Authorization': 'secret'};
    final params = <String, dynamic>{
      'url': 'https://example.com',
      'headers': headers,
    };
    final call = registry.validate('web_request', params);
    headers['Authorization'] = 'changed';
    params['method'] = 'DELETE';
    expect(call.params['method'], 'GET');
    expect(call.params['headers']['Authorization'], 'secret');
    expect(() => call.params['method'] = 'POST', throwsUnsupportedError);
    expect(
      () => call.params['headers']['Authorization'] = 'changed',
      throwsUnsupportedError,
    );
  });

  test('success requires trusted evidence and failure wins contradictions', () {
    expect(ToolRegistry.classifyResult(), ToolResultClassification.unknown);
    expect(
      ToolRegistry.classifyResult(succeeded: true),
      ToolResultClassification.succeeded,
    );
    expect(
      ToolRegistry.classifyResult(httpStatus: 204),
      ToolResultClassification.succeeded,
    );
    expect(
      ToolRegistry.classifyResult(httpStatus: 302),
      ToolResultClassification.failed,
    );
    expect(
      ToolRegistry.classifyResult(succeeded: true, httpStatus: 500),
      ToolResultClassification.failed,
    );
    expect(
      ToolRegistry.classifyResult(succeeded: true, threw: true),
      ToolResultClassification.failed,
    );
    expect(ToolRegistry.isFailureResult('ERROR: permission denied'), isTrue);
    expect(ToolRegistry.isFailureResult('❌ Error opening app'), isTrue);
  });

  test(
    'plan and done validate their internal schemas',
    () async {
      final task = registry.validate('execute_task', {'goal': 'Do work'});
      expect((await policy.authorize(task)).allowed, isTrue);
      expect(
        (await policy.authorize(
          registry.validate('click_element', {'text': 'Send'}),
        )).allowed,
        isTrue,
      );
      expect(
        () => registry.validate('plan', {
          'subtasks': [
            {'id': 'x'},
          ],
        }),
        throwsA(isA<ToolValidationException>()),
      );
      expect(
        () => registry.validate('done', {
          'evidence': {'x': 'success'},
        }),
        throwsA(isA<ToolValidationException>()),
      );
      expect(
        registry.validate('done', {
          'evidence': {
            'x': {
              'criterion': ['action-1'],
            },
          },
        }).name,
        'done',
      );
    },
  );

  test('approval preview removes URL secrets and shell arguments', () {
    final web = registry.validate('web_request', {
      'url': 'https://alice:secret@example.com/private?token=secret#secret',
      'method': 'POST',
      'headers': {'Authorization': 'secret'},
      'body': 'secret',
    });
    expect(ToolPolicy.safePreview(web), contains('example.com'));
    expect(ToolPolicy.safePreview(web), contains('POST'));
    expect(ToolPolicy.safePreview(web), isNot(contains('secret')));
    final shell = registry.validate('run_adb_command', {
      'command': 'sh -c secret',
    });
    expect(ToolPolicy.safePreview(shell), isNot(contains('secret')));
  });
}

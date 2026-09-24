import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/shizuku_service.dart';

void main() {
  test('preserves separate output streams and the process exit code', () {
    final result = ShizukuCommandResult.fromPlatformMap({
      'stdout': 'out\n',
      'stderr': 'err\n',
      'exitCode': 7,
      'wasDispatched': true,
      'error': null,
    });

    expect(result.stdout, 'out\n');
    expect(result.stderr, 'err\n');
    expect(result.exitCode, 7);
    expect(result.succeeded, isFalse);
    expect(result.uncertain, isTrue);
    expect(result.displayText, contains('Exit code: 7'));
    expect(result.displayText, contains('partial effects'));
  });

  test('a dispatched command without a result remains uncertain', () {
    const result = ShizukuCommandResult(
      stdout: 'partial output',
      stderr: '',
      exitCode: null,
      wasDispatched: true,
    );

    expect(result.succeeded, isFalse);
    expect(result.uncertain, isTrue);
    expect(result.displayText, contains('Review device state'));
  });

  test('a command blocked before dispatch is not treated as uncertain', () {
    const result = ShizukuCommandResult(
      stdout: '',
      stderr: '',
      exitCode: null,
      wasDispatched: false,
      error: 'Shizuku is not running.',
    );

    expect(result.succeeded, isFalse);
    expect(result.uncertain, isFalse);
    expect(result.displayText, contains('Shizuku is not running.'));
  });

  test('exit zero is technical success, not uncertain outcome', () {
    const result = ShizukuCommandResult(
      stdout: '',
      stderr: '',
      exitCode: 0,
      wasDispatched: true,
    );

    expect(result.succeeded, isTrue);
    expect(result.uncertain, isFalse);
    expect(result.displayText, contains('Exit code: 0'));
  });
}
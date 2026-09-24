import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/user_assistance_policy.dart';

void main() {
  const policy = UserAssistancePolicy();

  UserAssistanceDecision evaluate({
    String question =
        'Sign in directly on the page, then return and tap Done. Do not send credentials here.',
    String blockerType = 'sign_in',
    String evidence = 'Sign in to continue',
    List<String> attemptedStrategies = const [
      'web_request',
      'open_app',
      'read_screen',
    ],
    List<String> remainingStrategies = const [],
    Set<String> attemptedActions = const {
      'web_request',
      'open_app',
      'read_screen',
    },
    String currentScreen = 'Sign in to continue. Password field.',
    String previousResult = 'The account page requires sign in.',
    List<String> failedStrategies = const ['web_request: authentication required'],
  }) => policy.evaluate(
    question: question,
    blockerType: blockerType,
    evidence: evidence,
    attemptedStrategies: attemptedStrategies,
    remainingStrategies: remainingStrategies,
    attemptedActions: attemptedActions,
    currentScreen: currentScreen,
    previousResult: previousResult,
    failedStrategies: failedStrategies,
  );

  test('allows a grounded human-only sign-in after recorded actions', () {
    expect(evaluate().allowed, isTrue);
  });

  test('rejects an ungrounded or speculative blocker', () {
    final decision = evaluate(
      currentScreen: 'The account home page is open.',
      previousResult: 'Screen successfully read.',
      failedStrategies: const [],
    );

    expect(decision.allowed, isFalse);
    expect(decision.reason, contains('actual screen or tool result'));
  });

  test('rejects help requests while an automated strategy remains', () {
    expect(
      evaluate(remainingStrategies: const ['open_url']).allowed,
      isFalse,
    );
  });

  test('rejects strategies the executor did not actually attempt', () {
    expect(
      evaluate(
        attemptedStrategies: const ['web_request', 'run_adb_command'],
        attemptedActions: const {'web_request', 'open_app', 'read_screen'},
      ).allowed,
      isFalse,
    );
  });

  test('rejects asking the user to disclose a password or code', () {
    expect(
      evaluate(question: 'What is your verification code?').allowed,
      isFalse,
    );
  });

  test('rejects credential values that could leak into task history', () {
    expect(
      evaluate(
        evidence: 'Password: hunter2',
        currentScreen: 'Password: hunter2',
        previousResult: 'The sign-in page is open.',
      ).allowed,
      isFalse,
    );
    expect(
      evaluate(
        question: 'Sign in using alice@example.com, then tap Done.',
      ).allowed,
      isFalse,
    );
  });

  test('allows direct Android permission recovery based on observed error', () {
    final decision = evaluate(
      question:
          'Enable Screen Control in Android Settings, then return and tap Done.',
      blockerType: 'system_permission',
      evidence: 'Accessibility service is not enabled',
      attemptedStrategies: const ['read_screen'],
      attemptedActions: const {'read_screen'},
      currentScreen: 'Accessibility service is not enabled.',
      previousResult: 'UI cannot be used.',
      failedStrategies: const [],
    );

    expect(decision.allowed, isTrue);
  });

  test('allows private data to be entered directly into the target form', () {
    final decision = evaluate(
      question:
          'Enter the date of birth directly in the form, then return and tap Done.',
      blockerType: 'private_data',
      evidence: 'Date of birth',
      attemptedStrategies: const ['open_url', 'read_screen'],
      attemptedActions: const {'open_url', 'read_screen'},
      currentScreen: 'This form requires Date of birth.',
      previousResult: 'Form opened.',
      failedStrategies: const [],
    );

    expect(decision.allowed, isTrue);
  });
}
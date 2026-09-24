class UserAssistanceDecision {
  const UserAssistanceDecision(this.allowed, this.reason);

  final bool allowed;
  final String reason;
}

/// Runtime gate for questions that ask the user to perform a human-only step.
class UserAssistancePolicy {
  const UserAssistancePolicy();

  static const timeLimit = Duration(minutes: 5);
  static const completedReply = 'human_step_completed';
  static const declinedReply = 'human_step_not_now';

  static const _allowedBlockerTypes = {
    'sign_in',
    'private_data',
    'system_permission',
    'human_verification',
  };
  static const _nonStrategyActions = {
    'ask_user',
    'done',
    'plan',
    'read_screen',
    'wait',
  };

  UserAssistanceDecision evaluate({
    required String question,
    required String blockerType,
    required String evidence,
    required List<String> attemptedStrategies,
    required List<String> remainingStrategies,
    required Set<String> attemptedActions,
    required String currentScreen,
    required String previousResult,
    required List<String> failedStrategies,
  }) {
    if (!_allowedBlockerTypes.contains(blockerType)) {
      return const UserAssistanceDecision(
        false,
        'Only a verified sign-in, private-data, Android permission, or human-verification blocker can require help.',
      );
    }
    if (question.trim().isEmpty || question.length > 320) {
      return const UserAssistanceDecision(false, 'The question is invalid.');
    }
    if (_asksForCredentials(question) ||
        _containsSensitiveValue(question) ||
        _containsSensitiveValue(evidence)) {
      return const UserAssistanceDecision(
        false,
        'Credentials and private values must not be included in the help request.',
      );
    }
    if (evidence.trim().length < 4 || evidence.trim().length > 120) {
      return const UserAssistanceDecision(
        false,
        'The blocker needs a short, specific observed phrase.',
      );
    }

    final observationSources = [
      currentScreen,
      previousResult,
      ...failedStrategies,
    ];
    if (!_containsNormalized(observationSources, evidence)) {
      return const UserAssistanceDecision(
        false,
        'The cited evidence was not present in an actual screen or tool result.',
      );
    }
    if (!_hasUserOnlySignal(blockerType, evidence)) {
      return const UserAssistanceDecision(
        false,
        'The observed evidence does not establish a user-only blocker.',
      );
    }
    if (remainingStrategies.isNotEmpty) {
      return const UserAssistanceDecision(
        false,
        'An automated strategy is still available.',
      );
    }
    if (attemptedStrategies.isEmpty) {
      return const UserAssistanceDecision(
        false,
        'No automated strategy has been attempted.',
      );
    }

    final actualActions = attemptedActions
        .map((action) => action.trim().toLowerCase())
        .toSet();
    final claimedActions = attemptedStrategies
        .map((action) => action.trim().toLowerCase())
        .toSet();
    if (claimedActions.any((action) => action.isEmpty || !actualActions.contains(action))) {
      return const UserAssistanceDecision(
        false,
        'The attempted-strategy list does not match executed actions.',
      );
    }
    final hasSubstantiveAttempt = claimedActions
        .any((action) => !_nonStrategyActions.contains(action));
    final directlyHumanOnly = const {
      'system_permission',
      'human_verification',
    }.contains(blockerType);
    if (!hasSubstantiveAttempt && !directlyHumanOnly) {
      return const UserAssistanceDecision(
        false,
        'At least one substantive automated action must be attempted first.',
      );
    }

    return const UserAssistanceDecision(
      true,
      'A user-only blocker is supported by actual evidence and no automated strategies remain.',
    );
  }

  static bool _containsNormalized(Iterable<String> sources, String evidence) {
    final needle = _normalize(evidence);
    return sources.any((source) => _normalize(source).contains(needle));
  }

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool _hasUserOnlySignal(String blockerType, String evidence) {
    final pattern = switch (blockerType) {
      'sign_in' =>
        r'\b(sign[\s-]?in|log[\s-]?in|password|passcode|authentication required|verification code|one[- ]time code|otp|passkey)\b',
      'private_data' =>
        r'\b(email|e-mail|phone|mobile|address|date of birth|birth date|credit card|card number|tax id|social security|ssn|medical|private data|personal information|passport|identity document)\b',
      'system_permission' =>
        r'\b(accessibility|permission denied|permission required|not granted|not enabled|restricted setting|system settings|screen control|allow restricted)\b',
      'human_verification' =>
        r'\b(captcha|verify you are human|human verification|biometric|fingerprint|face id|verification code|one[- ]time code|physical confirmation|press and hold)\b',
      _ => r'(?!)',
    };
    return RegExp(pattern, caseSensitive: false).hasMatch(evidence);
  }

  static bool _asksForCredentials(String question) {
    const secret =
        r'(?:passwords?|passcodes?|verification codes?|one[- ]time codes?|otps?|tokens?|api keys?|secrets?|recovery codes?|credentials|codes?)';
    final asksForSecret =
        RegExp(
          r"\bwhat(?:\s+is|'s)\s+(?:your\s+)?"
              + secret +
              r'\b',
          caseSensitive: false,
        ).hasMatch(question) ||
        RegExp(
          r'\b(?:tell|send|share|reply with|provide)(?:\s+(?:me with|with me|me))?\s+(?:(?:your|the)\s+)?'
              + secret +
              r'\b',
          caseSensitive: false,
        ).hasMatch(question) ||
        RegExp(
          r'\b(?:paste|type|enter)\s+(?:your\s+)?'
              + secret +
              r'\s+(?:here|into (?:this )?chat)\b',
          caseSensitive: false,
        ).hasMatch(question);
    final explicitlyProhibitsDisclosure = RegExp(
      r"\b(?:do not|don't|never|avoid)\s+(?:tell|send|share|reply|provide|paste|type|enter)\b.{0,60}\b"
          + secret +
          r'\b',
      caseSensitive: false,
    ).hasMatch(question);
    return asksForSecret && !explicitlyProhibitsDisclosure;
  }

  static bool _containsSensitiveValue(String text) {
    return RegExp(
          r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
          caseSensitive: false,
        ).hasMatch(text) ||
        RegExp(
          r'\b(?:password|passcode|verification code|one[- ]time code|otp|token|api key|secret|recovery code)\s*[:=]\s*\S+',
          caseSensitive: false,
        ).hasMatch(text) ||
        RegExp(r'\b\+?\d[\d\s().-]{7,}\d\b').hasMatch(text) ||
        RegExp(r'\b(?:\d[ -]*?){13,19}\b').hasMatch(text) ||
        RegExp(r'\b[A-Za-z0-9_-]{32,}\b').hasMatch(text);
  }
}
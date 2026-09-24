import 'tool_registry.dart';
import '../privacy_sanitizer.dart';

typedef ToolApprovalCallback = Future<bool> Function(ToolApprovalRequest);

/// Safe to display/persist: intentionally contains no raw arguments, URLs,
/// commands, paths, recipients, content, headers, or model-provided reasoning.
class ToolApprovalRequest {
  ToolApprovalRequest._(ValidatedToolCall call)
      : toolName = call.name,
        capability = call.definition.capability,
        risk = call.risk,
        mutation = call.mutation,
        summary = ToolPolicy.sanitizedSummary(call),
        preview = ToolPolicy.safePreview(call);
  final String toolName;
  final ToolCapability capability;
  final ToolRisk risk;
  final ToolMutation mutation;
  final String summary;
  final String preview;
}

class ToolPolicyDecision {
  const ToolPolicyDecision(this.allowed, this.reason);
  final bool allowed;
  final String reason;
}

class ToolPolicy {
  const ToolPolicy();

  bool isMutation(ValidatedToolCall call) =>
      call.mutation != ToolMutation.readOnly;

  /// A user's task request authorizes its validated tool calls. An optional
  /// host callback may still explicitly veto a call on channels that cannot
  /// execute autonomously. Check cancellation again after this future returns.
  Future<ToolPolicyDecision> authorize(
    ValidatedToolCall call, {ToolApprovalCallback? onApproval}
  ) async {
    if (!isMutation(call)) {
      return const ToolPolicyDecision(true, 'Read-only operation.');
    }
    if (onApproval == null) {
      return const ToolPolicyDecision(
        true,
        'The user task authorizes this validated operation.',
      );
    }
    try {
      final allowed = await onApproval(ToolApprovalRequest._(call));
      return ToolPolicyDecision(
        allowed,
        allowed
            ? 'The host allowed this operation.'
            : 'The host denied this operation.',
      );
    } catch (_) {
      return const ToolPolicyDecision(false, 'The host policy could not be applied.');
    }
  }

  static String sanitizedSummary(ValidatedToolCall call) {
    final effect = switch (call.mutation) {
      ToolMutation.readOnly => 'Read information',
      ToolMutation.write => 'Create or replace data',
      ToolMutation.delete => 'Permanently delete data',
      ToolMutation.externalEffect => 'Perform an action with possible external side effects',
      ToolMutation.arbitrary => 'Perform operations with unrestricted side effects',
    };
    return '$effect using ${call.name}. Parameter values are hidden for privacy.';
  }

  static Map<String, String> sanitizedEvidence(
      ValidatedToolCall call, ToolResultClassification result) =>
      Map.unmodifiable({
        'tool': call.name,
        'capability': call.definition.capability.name,
        'mutation': call.mutation.name,
        'result': result.name,
      });

  /// Allowlisted target metadata only; never bodies, headers, query strings,
  /// shell arguments, text being typed, or unrestricted UI/model prose.
  static String safePreview(ValidatedToolCall call) =>
      PrivacySanitizer.sanitizeText(_safePreview(call));

  static String _safePreview(ValidatedToolCall call) {
    final p = call.params;
    switch (call.name) {
      case 'web_request':
      case 'open_url':
        final uri = Uri.tryParse(p['url'] as String);
        final host = uri?.host ?? '';
        final safeHost = RegExp(r'^[a-zA-Z0-9.-]{1,100}$').hasMatch(host)
            ? host : '[hidden host]';
        return 'Destination host: $safeHost\n'
            'Method: ${p['method'] ?? 'external app launch'}\n'
            'Credentials, path, query, headers and body are hidden. '
            'The destination may receive private data.';
      case 'write_file':
      case 'delete_file':
        final path = p['path'] as String;
        final basename = path.split('/').last;
        final safe = RegExp(r'^[a-zA-Z0-9 _.-]{1,48}$').hasMatch(basename) &&
            !RegExp(r'token|secret|password|api.?key|bearer', caseSensitive: false).hasMatch(basename);
        return 'Private agent_files target: ${safe ? basename : '[name hidden]'}\n'
            '${call.name == 'delete_file' ? 'Permanently removes one file.' : 'Creates or replaces the entire file (${(p['content'] as String).length} characters). Existing contents will be lost.'}';
      case 'run_adb_command':
        final executable = (p['command'] as String).trim().split(RegExp(r'\s+')).first;
        final safe = const ['input', 'am', 'pm', 'settings', 'cmd', 'ls', 'cat', 'echo', 'rm', 'sh'].contains(executable);
        return 'Elevated Android shell. Program: ${safe ? executable : '[hidden]'}.\n'
            'Arguments hidden; arbitrary commands may delete data, send information, or change system settings. Deny if the intended command is unclear.';
      case 'send_sms':
      case 'make_call':
        final phone = p['phone_number'] as String?;
        final digits = phone?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
        return 'Recipient: ${digits.length >= 2 ? 'number ending ${digits.substring(digits.length - 2)}' : 'named contact (identity hidden)'}.\n'
            '${call.name == 'make_call' ? 'Places a phone call; charges may apply.' : 'Sends ${(p['message'] as String).length} characters; message contents hidden.'}';
      case 'send_email':
        final address = p['to'] as String;
        final domain = address.split('@').last;
        final safeDomain = address.contains('@') &&
            RegExp(r'^[a-zA-Z0-9.-]{1,100}$').hasMatch(domain);
        return 'Recipient: hidden mailbox at ${safeDomain ? domain : '[hidden domain]'}.\n'
            'Opens a compose/send action for one recipient; ${(p['body'] as String? ?? '').length} body characters.';
      case 'open_app':
      case 'launch_package':
        final target = (p['app_name'] ?? p['package_name']) as String;
        final safeTarget = RegExp(r'^[a-zA-Z0-9 ._-]{1,64}$').hasMatch(target);
        return 'Launch app: ${safeTarget ? target : '[name hidden]'}.\n'
            'The app will open on this device and may initiate its own background activity.';
      case 'click_at':
        return 'Tap screen position (${p['x']}, ${p['y']}). This can activate a send, purchase, or destructive control.';
      case 'click_text':
        final label = (p['text'] as String).toLowerCase();
        return 'Activate ${const ['send', 'delete', 'ok', 'cancel', 'save', 'buy', 'confirm', 'yes', 'no', 'search'].contains(label) ? '"$label"' : 'a text-matched control (label hidden)'} on the current screen. This may commit an irreversible action.';
      case 'type_text':
        return 'Type ${(p['text'] as String).length} characters into the focused/matched field. Text is hidden; the app may transmit it immediately.';
      case 'set_volume':
      case 'set_brightness':
        return 'Set device level to ${p['level']}%.';
      case 'set_alarm':
        return 'Set alarm at ${p['hour']}:${p['minute']}. Label hidden.';
      case 'set_timer':
        return 'Start a ${p['seconds']}-second timer.';
      case 'scroll':
        return 'Scroll ${p['direction']} on the current screen; may trigger app actions.';
      default:
        return 'Target: current Android device/app. Action: ${call.name}. '
            'This may navigate away, submit a form, or change application state.';
    }
  }
}
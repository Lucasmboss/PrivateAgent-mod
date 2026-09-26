import 'dart:convert';

enum ToolCapability {
  network,
  privateFiles,
  contacts,
  communication,
  device,
  shell,
  accessibility,
  orchestration,
}

enum ToolRisk { low, sensitive, destructive, privileged }

enum ToolMutation { readOnly, write, delete, externalEffect, arbitrary }

enum ToolResultClassification { succeeded, failed, unknown }

class ToolValidationException implements Exception {
  const ToolValidationException(this.message);
  final String message;
  @override
  String toString() => 'ToolValidationException: $message';
}

class ToolDefinition {
  const ToolDefinition(
    this.name,
    this.capability,
    this.mutation,
    this.risk,
    this.schema, {
    this.aliases = const [],
  });
  final String name;
  final ToolCapability capability;
  final ToolMutation mutation;
  final ToolRisk risk;

  /// Type names with `!` denote required parameters.
  final Map<String, String> schema;
  final List<String> aliases;
}

/// An immutable, validated snapshot. Dispatch these params, not the original map.
class ValidatedToolCall {
  ValidatedToolCall._(this.definition, this.params);
  final ToolDefinition definition;
  final Map<String, dynamic> params;
  String get name => definition.name;
  ToolMutation get mutation => name == 'web_request'
      ? const ['GET', 'HEAD'].contains(params['method'])
            ? ToolMutation.readOnly
            : ToolMutation.externalEffect
      : definition.mutation;
  ToolRisk get risk =>
      name == 'web_request' && mutation == ToolMutation.readOnly
      ? ToolRisk.low
      : definition.risk;
}

class ToolRegistry {
  const ToolRegistry();
  static const definitions = <ToolDefinition>[
    ToolDefinition(
      'web_search',
      ToolCapability.network,
      ToolMutation.readOnly,
      ToolRisk.low,
      {'query': 'string!'},
    ),
    ToolDefinition(
      'web_request',
      ToolCapability.network,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {
        'url': 'string!',
        'method': 'string',
        'headers': 'headers',
        'body': 'body',
      },
    ),
    ToolDefinition(
      'list_files',
      ToolCapability.privateFiles,
      ToolMutation.readOnly,
      ToolRisk.low,
      {},
    ),
    ToolDefinition(
      'read_file',
      ToolCapability.privateFiles,
      ToolMutation.readOnly,
      ToolRisk.low,
      {'path': 'string!'},
    ),
    ToolDefinition(
      'write_file',
      ToolCapability.privateFiles,
      ToolMutation.write,
      ToolRisk.destructive,
      {'path': 'string!', 'content': 'text!'},
    ),
    ToolDefinition(
      'delete_file',
      ToolCapability.privateFiles,
      ToolMutation.delete,
      ToolRisk.destructive,
      {'path': 'string!'},
    ),
    ToolDefinition(
      'search_contact',
      ToolCapability.contacts,
      ToolMutation.readOnly,
      ToolRisk.low,
      {'query': 'string!'},
    ),
    ToolDefinition(
      'make_call',
      ToolCapability.communication,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {'contact_name': 'string', 'phone_number': 'string'},
    ),
    ToolDefinition(
      'send_sms',
      ToolCapability.communication,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {
        'contact_name': 'string',
        'phone_number': 'string',
        'message': 'string!',
      },
    ),
    ToolDefinition(
      'send_email',
      ToolCapability.communication,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {'to': 'string!', 'subject': 'text', 'body': 'text'},
    ),
    ToolDefinition(
      'open_app',
      ToolCapability.device,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {'app_name': 'string!'},
    ),
    ToolDefinition(
      'launch_package',
      ToolCapability.device,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {'package_name': 'string!'},
    ),
    ToolDefinition(
      'open_url',
      ToolCapability.device,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {'url': 'string!'},
    ),
    ToolDefinition(
      'set_alarm',
      ToolCapability.device,
      ToolMutation.write,
      ToolRisk.sensitive,
      {'hour': 'int!', 'minute': 'int!', 'label': 'text'},
    ),
    ToolDefinition(
      'set_timer',
      ToolCapability.device,
      ToolMutation.write,
      ToolRisk.sensitive,
      {'seconds': 'int!', 'label': 'text'},
    ),
    ToolDefinition(
      'set_volume',
      ToolCapability.device,
      ToolMutation.write,
      ToolRisk.sensitive,
      {'level': 'int!'},
    ),
    ToolDefinition(
      'set_brightness',
      ToolCapability.device,
      ToolMutation.write,
      ToolRisk.sensitive,
      {'level': 'int!'},
    ),
    ToolDefinition(
      'run_adb_command',
      ToolCapability.shell,
      ToolMutation.arbitrary,
      ToolRisk.privileged,
      {'command': 'string!'},
    ),
    ToolDefinition(
      'read_screen',
      ToolCapability.accessibility,
      ToolMutation.readOnly,
      ToolRisk.low,
      {},
    ),
    ToolDefinition(
      'click_text',
      ToolCapability.accessibility,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {'text': 'string!'},
      aliases: ['click_element'],
    ),
    ToolDefinition(
      'click_at',
      ToolCapability.accessibility,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {'x': 'number!', 'y': 'number!'},
    ),
    ToolDefinition(
      'type_text',
      ToolCapability.accessibility,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {'text': 'text!', 'field_hint': 'string'},
      aliases: ['type_on_screen'],
    ),
    ToolDefinition(
      'scroll',
      ToolCapability.accessibility,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {'direction': 'string!'},
      aliases: ['scroll_screen'],
    ),
    ToolDefinition(
      'swipe',
      ToolCapability.accessibility,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {
        'startX': 'number!',
        'startY': 'number!',
        'endX': 'number!',
        'endY': 'number!',
        'duration': 'int',
      },
    ),
    ToolDefinition(
      'press_enter',
      ToolCapability.accessibility,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {},
    ),
    ToolDefinition(
      'press_back',
      ToolCapability.accessibility,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {},
    ),
    ToolDefinition(
      'press_home',
      ToolCapability.accessibility,
      ToolMutation.externalEffect,
      ToolRisk.sensitive,
      {},
    ),
    ToolDefinition(
      'wait',
      ToolCapability.orchestration,
      ToolMutation.readOnly,
      ToolRisk.low,
      {'milliseconds': 'int!'},
    ),
    ToolDefinition(
      'ask_user',
      ToolCapability.orchestration,
      ToolMutation.readOnly,
      ToolRisk.low,
      {
        'question': 'string!',
        'blocker_type': 'string!',
        'evidence': 'string!',
        'attempted_strategies': 'string_list!',
        'remaining_strategies': 'string_list!',
      },
    ),
    ToolDefinition(
      'plan',
      ToolCapability.orchestration,
      ToolMutation.readOnly,
      ToolRisk.low,
      {'subtasks': 'plan!'},
    ),
    ToolDefinition(
      'subtask_failed',
      ToolCapability.orchestration,
      ToolMutation.readOnly,
      ToolRisk.low,
      {
        'subtask_id': 'string!',
        'failure_code': 'string!',
        'attempted_strategies': 'string_list!',
        'remaining_strategies': 'string_list!',
      },
    ),
    ToolDefinition(
      'done',
      ToolCapability.orchestration,
      ToolMutation.readOnly,
      ToolRisk.low,
      {'evidence': 'evidence'},
    ),
    ToolDefinition(
      'execute_task',
      ToolCapability.orchestration,
      ToolMutation.readOnly,
      ToolRisk.low,
      {'goal': 'string!', 'resume_task_id': 'string'},
    ),
  ];

  ToolDefinition? lookup(String name) {
    final normalized = name.trim().toLowerCase();
    for (final definition in definitions) {
      if (definition.name == normalized ||
          definition.aliases.contains(normalized)) {
        return definition;
      }
    }
    return null;
  }

  ValidatedToolCall validate(String name, Map<String, dynamic> params) {
    final definition = lookup(name);
    if (definition == null) {
      throw const ToolValidationException('Unknown tool.');
    }
    void invalid() =>
        throw const ToolValidationException('Invalid tool parameters.');
    if (params.keys.any((key) => !definition.schema.containsKey(key)))
      invalid();
    for (final entry in definition.schema.entries) {
      final required = entry.value.endsWith('!');
      final type = entry.value.replaceAll('!', '');
      final value = params[entry.key];
      if (!params.containsKey(entry.key)) {
        if (required) invalid();
        continue;
      }
      final valid = switch (type) {
        'string' => value is String && value.trim().isNotEmpty,
        'text' => value is String,
        'int' => value is int,
        'number' => value is num && value.isFinite,
        'string_list' =>
          value is List &&
              value.every((item) => item is String && item.trim().isNotEmpty),
        'headers' =>
          value is Map &&
              value.entries.every((e) => e.key is String && e.value is String),
        'body' =>
          value == null || value is String || value is Map || value is List,
        'plan' =>
          value is List &&
              value.isNotEmpty &&
              value.every(
                (s) =>
                    s is Map &&
                    s['id'] is String &&
                    s['objective'] is String &&
                    s['criteria'] is List &&
                    (s['criteria'] as List).every((c) => c is String) &&
                    (s['dependencies'] == null ||
                        s['dependencies'] is List &&
                            (s['dependencies'] as List).every(
                              (d) => d is String,
                            )) &&
                    !s.containsKey('evidenceRefs'),
              ),
        'evidence' =>
          value is Map &&
              value.entries.every(
                (s) =>
                    s.key is String &&
                    s.value is Map &&
                    (s.value as Map).entries.every(
                      (c) =>
                          c.key is String &&
                          c.value is List &&
                          (c.value as List).every((r) => r is String),
                    ),
              ),
        _ => false,
      };
      if (!valid) invalid();
    }
    if (const ['make_call', 'send_sms'].contains(definition.name) &&
        !params.containsKey('contact_name') &&
        !params.containsKey('phone_number'))
      invalid();
    if (definition.name == 'scroll' &&
        !const ['up', 'down', 'left', 'right'].contains(params['direction']))
      invalid();
    for (final key in [
      'x',
      'y',
      'startX',
      'startY',
      'endX',
      'endY',
      'milliseconds',
      'duration',
    ]) {
      if (params[key] is num && (params[key] as num) < 0) invalid();
    }
    for (final bound in {'hour': 23, 'minute': 59, 'level': 100}.entries) {
      final value = params[bound.key];
      if (value is int && (value < 0 || value > bound.value)) invalid();
    }
    if (params['seconds'] is int && (params['seconds'] as int) <= 0) invalid();
    Map<String, dynamic> snapshot;
    try {
      snapshot = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(params)) as Map,
      );
    } catch (_) {
      throw const ToolValidationException('Parameters must be JSON values.');
    }
    if (definition.name == 'web_request') {
      final method = (snapshot['method'] as String? ?? 'GET')
          .trim()
          .toUpperCase();
      if (!const {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'}.contains(method)) {
        invalid();
      }
      snapshot['method'] = method;
      final uri = Uri.tryParse(snapshot['url'] as String);
      if (uri == null ||
          !const ['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty)
        invalid();
    }
    return ValidatedToolCall._(
      definition,
      _freeze(snapshot) as Map<String, dynamic>,
    );
  }

  static dynamic _freeze(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.unmodifiable(
        value.map((k, v) => MapEntry(k as String, _freeze(v))),
      );
    }
    if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
    return value;
  }

  /// Only trusted adapter evidence may establish success. Never infer success
  /// from arbitrary tool text, model claims, or absence of an error substring.
  static ToolResultClassification classifyResult({
    bool? succeeded,
    int? httpStatus,
    bool threw = false,
  }) {
    if (threw ||
        succeeded == false ||
        (httpStatus != null && (httpStatus < 200 || httpStatus >= 300))) {
      return ToolResultClassification.failed;
    }
    if (succeeded == true ||
        (httpStatus != null && httpStatus >= 200 && httpStatus < 300)) {
      return ToolResultClassification.succeeded;
    }
    return ToolResultClassification.unknown;
  }

  /// Negative evidence only: text can disprove success, never prove it.
  static bool isFailureResult(String text) => RegExp(
    r'(^|\n|\s)(error\b|failed\b|failure\b|could not\b|cannot\b|permission denied\b|not running\b)',
    caseSensitive: false,
  ).hasMatch(text);
}

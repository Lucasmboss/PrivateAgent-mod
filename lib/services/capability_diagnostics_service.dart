import 'dart:io';

import 'file_service.dart';
import 'shizuku_service.dart';
import 'tool_registry.dart';
import 'web_search_service.dart';
import 'web_service.dart';

enum CapabilityDiagnosticStatus {
  passed,
  failed,
  unavailable,
  notTested,
}

class _CapabilityDiagnosticEntry {
  const _CapabilityDiagnosticEntry(this.status, this.detail);

  final CapabilityDiagnosticStatus status;
  final String detail;
}

/// Safe, read-only capability checks. Probe output is reduced to status text
/// before it leaves this service; response bodies, file names, and device
/// values are never included in the report.
class CapabilityDiagnosticsService {
  CapabilityDiagnosticsService({
    required Future<String> Function(String query) search,
    required Future<int?> Function(String url) publicGetStatus,
    required Future<List<String>> Function() listFiles,
    required Future<bool> Function() isAndroid,
    required Future<bool> Function() shizukuReady,
    required Future<ShizukuCommandResult> Function() readBattery,
    List<ToolDefinition>? tools,
  }) : _search = search,
       _publicGetStatus = publicGetStatus,
       _listFiles = listFiles,
       _isAndroid = isAndroid,
       _shizukuReady = shizukuReady,
       _readBattery = readBattery,
       _tools = tools ?? ToolRegistry.definitions;

  factory CapabilityDiagnosticsService.forApp({
    required WebSearchService webSearch,
    required WebService webService,
    required FileService fileService,
    required ShizukuService shizukuService,
  }) => CapabilityDiagnosticsService(
    search: webSearch.search,
    publicGetStatus: (url) => webService.getStatusOnly(url: url),
    listFiles: () => fileService.listFiles(),
    isAndroid: () async => Platform.isAndroid,
    shizukuReady: () async {
      await shizukuService.checkAvailability();
      return shizukuService.isAvailable && shizukuService.hasPermission;
    },
    readBattery: shizukuService.readBatteryForDiagnostics,
  );

  static const String _publicStatusUrl =
      'https://api.ipify.org?format=json';

  final Future<String> Function(String query) _search;
  final Future<int?> Function(String url) _publicGetStatus;
  final Future<List<String>> Function() _listFiles;
  final Future<bool> Function() _isAndroid;
  final Future<bool> Function() _shizukuReady;
  final Future<ShizukuCommandResult> Function() _readBattery;
  final List<ToolDefinition> _tools;

  Future<String> run() async {
    final entries = <String, _CapabilityDiagnosticEntry>{
      for (final tool in _tools)
        tool.name: const _CapabilityDiagnosticEntry(
          CapabilityDiagnosticStatus.notTested,
          'Not exercised by this safe diagnostic.',
        ),
    };

    entries['capability_diagnostic'] = const _CapabilityDiagnosticEntry(
      CapabilityDiagnosticStatus.passed,
      'This read-only report completed.',
    );

    try {
      final searchResult = await _search('read-only capability diagnostic');
      final passed = searchResult.startsWith('SEARCH RESULTS');
      entries['web_search'] = _CapabilityDiagnosticEntry(
        passed
            ? CapabilityDiagnosticStatus.passed
            : CapabilityDiagnosticStatus.failed,
        passed
            ? 'A search response was received; result content was discarded.'
            : 'The search probe did not return usable results.',
      );
    } catch (_) {
      entries['web_search'] = const _CapabilityDiagnosticEntry(
        CapabilityDiagnosticStatus.failed,
        'The search probe failed; response details were discarded.',
      );
    }

    try {
      final status = await _publicGetStatus(_publicStatusUrl);
      entries['web_request'] = _CapabilityDiagnosticEntry(
        status != null && status >= 200 && status < 400
            ? CapabilityDiagnosticStatus.passed
            : CapabilityDiagnosticStatus.failed,
        status == null
            ? 'The public GET probe returned no HTTP status.'
            : 'Public GET returned HTTP $status; the response body was discarded.',
      );
    } catch (_) {
      entries['web_request'] = const _CapabilityDiagnosticEntry(
        CapabilityDiagnosticStatus.failed,
        'The public GET probe failed; response details were discarded.',
      );
    }

    try {
      await _listFiles();
      entries['list_files'] = const _CapabilityDiagnosticEntry(
        CapabilityDiagnosticStatus.passed,
        'Private file listing succeeded; file names were discarded.',
      );
    } catch (_) {
      entries['list_files'] = const _CapabilityDiagnosticEntry(
        CapabilityDiagnosticStatus.failed,
        'Private file listing failed; file names were not retained.',
      );
    }

    entries['read_file'] = const _CapabilityDiagnosticEntry(
      CapabilityDiagnosticStatus.notTested,
      'No designated non-sensitive fixture is available to read.',
    );

    var isAndroid = false;
    try {
      isAndroid = await _isAndroid();
    } catch (_) {
      isAndroid = false;
    }
    if (!isAndroid) {
      entries['run_adb_command'] = const _CapabilityDiagnosticEntry(
        CapabilityDiagnosticStatus.unavailable,
        'Android is not available in this environment.',
      );
    } else {
      var shizukuReady = false;
      try {
        shizukuReady = await _shizukuReady();
      } catch (_) {
        shizukuReady = false;
      }
      if (!shizukuReady) {
        entries['run_adb_command'] = const _CapabilityDiagnosticEntry(
          CapabilityDiagnosticStatus.unavailable,
          'Shizuku is unavailable or its existing permission is not granted; no prompt was shown.',
        );
      } else {
        try {
          final battery = await _readBattery();
          entries['run_adb_command'] = _CapabilityDiagnosticEntry(
            battery.succeeded
                ? CapabilityDiagnosticStatus.passed
                : battery.wasDispatched
                    ? CapabilityDiagnosticStatus.failed
                    : CapabilityDiagnosticStatus.unavailable,
            battery.succeeded
                ? 'The fixed, read-only battery status query succeeded; values were discarded.'
                : battery.wasDispatched
                    ? 'The read-only battery status query failed; output was discarded.'
                    : 'The battery status query was not dispatched.',
          );
        } catch (_) {
          entries['run_adb_command'] = const _CapabilityDiagnosticEntry(
            CapabilityDiagnosticStatus.failed,
            'The read-only battery status query failed; output was discarded.',
          );
        }
      }
    }

    final statusLabels = {
      CapabilityDiagnosticStatus.passed: 'Passed',
      CapabilityDiagnosticStatus.failed: 'Failed',
      CapabilityDiagnosticStatus.unavailable: 'Unavailable',
      CapabilityDiagnosticStatus.notTested: 'Not tested',
    };
    final buffer = StringBuffer()
      ..writeln('Capability diagnostic')
      ..writeln(
        'Safe probes only. No messages, calls, writes, deletions, screen actions, '
        'or arbitrary shell commands were run.',
      )
      ..writeln(
        'The public GET response body, private file names, search results, and '
        'device values were not included.',
      )
      ..writeln();
    for (final tool in _tools) {
      final entry = entries[tool.name]!;
      buffer.writeln(
        '${tool.name} (${tool.capability.name}) — '
        '${statusLabels[entry.status]}: ${entry.detail}',
      );
    }
    return buffer.toString().trim();
  }
}
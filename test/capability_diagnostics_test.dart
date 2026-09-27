import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/capability_diagnostics_service.dart';
import 'package:private_agent/services/tool_registry.dart';

void main() {
  test('reports tools while discarding search and file-list content', () async {
    String? searchQuery;
    String? requestedUrl;
    var batteryReads = 0;
    final diagnostic = CapabilityDiagnosticsService(
      search: (query) async {
        searchQuery = query;
        return 'SEARCH RESULTS private@example.test token=secret-search-value';
      },
      publicGetStatus: (url) async {
        requestedUrl = url;
        return 200;
      },
      listFiles: () async => const [
        '/private/photos/secret-document.txt',
      ],
      isAndroid: () async => true,
      shizukuReady: () async => false,
      readBattery: () async {
        batteryReads++;
        throw StateError('Battery read must not run without existing permission');
      },
    );

    final report = await diagnostic.run();

    expect(searchQuery, 'read-only capability diagnostic');
    expect(requestedUrl, 'https://api.ipify.org?format=json');
    expect(batteryReads, 0);
    expect(report, contains('web_search'));
    expect(report, contains('web_request'));
    expect(report, contains('list_files'));
    expect(report, contains('run_adb_command'));
    expect(report, contains('Not exercised by this safe diagnostic.'));
    expect(report, contains('response body was discarded'));
    expect(report, contains('no prompt was shown'));
    for (final tool in ToolRegistry.definitions) {
      expect(report, contains(tool.name));
    }
    expect(report, isNot(contains('private@example.test')));
    expect(report, isNot(contains('secret-search-value')));
    expect(report, isNot(contains('/private/photos/secret-document.txt')));
  });
}
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/chat_history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temporaryRoot;
  late Directory documentsDirectory;

  setUp(() async {
    temporaryRoot = await Directory.systemTemp.createTemp('chat-history-');
    documentsDirectory = Directory('${temporaryRoot.path}/app_flutter');
    SharedPreferences.setMockInitialValues({});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return documentsDirectory.path;
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await temporaryRoot.delete(recursive: true);
  });

  test(
    'concurrent saves create the directory and preserve every session',
    () async {
      final now = DateTime.now();
      final sessions = List.generate(
        24,
        (index) => ChatSession(
          id: 'session-$index',
          title: 'Session $index',
          timestamp: now.add(Duration(seconds: index)),
          messages: [
            {'role': 'user', 'content': 'Message $index'},
          ],
        ),
      );

      await Future.wait(sessions.map(ChatHistoryService.saveSession));

      expect(await documentsDirectory.exists(), isTrue);
      final savedSessions = await ChatHistoryService.loadSessions();
      expect(
        savedSessions.map((session) => session.id).toSet(),
        sessions.map((session) => session.id).toSet(),
      );
    },
  );
}

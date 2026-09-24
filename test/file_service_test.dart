import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/file_service.dart';

void main() {
  late Directory temporary;
  late FileService service;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('private-agent-files-');
    service = FileService(rootDirectory: temporary, maxReadBytes: 8, maxWriteBytes: 8);
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('writes, reads and lists private files', () async {
    await service.writeText('notes.txt', 'hello');
    expect(await service.readText('notes.txt'), 'hello');
    expect(await service.listFiles(), <String>['notes.txt']);
  });

  test('enforces byte limits and UTF-8', () async {
    await expectLater(service.writeText('large.txt', '123456789'), throwsA(isA<FileSizeLimitException>()));
    await File('${temporary.path}/bad.txt').writeAsBytes(<int>[0xc3, 0x28]);
    await expectLater(service.readText('bad.txt'), throwsA(isA<FileServiceException>()));
  });

  test('rejects traversal and absolute paths', () async {
    for (final path in <String>['../outside.txt', '/tmp/outside.txt', 'a/../../x', r'..\outside.txt']) {
      await expectLater(service.readText(path), throwsA(isA<FileServiceException>()));
      await expectLater(service.delete(path), throwsA(isA<FileServiceException>()));
    }
  });

  test('does not delete directories', () async {
    await Directory('${temporary.path}/folder').create();
    await expectLater(service.delete('folder'), throwsA(isA<FileServiceException>()));
    expect(await Directory('${temporary.path}/folder').exists(), isTrue);
  });

  test('does not silently delete a missing file', () async {
    await expectLater(
      service.delete('missing.txt'),
      throwsA(isA<FileServiceException>()),
    );
  });

  test('rejects a symlink that points outside the private directory', () async {
    final outside = await Directory.systemTemp.createTemp('private-agent-outside-');
    addTearDown(() async {
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    final outsideFile = File('${outside.path}/secret.txt');
    await outsideFile.writeAsString('secret');
    await Link('${temporary.path}/link.txt').create(outsideFile.path);

    await expectLater(
      service.delete('link.txt'),
      throwsA(isA<FileServiceException>()),
    );
    expect(await outsideFile.exists(), isTrue);
    expect(await Link('${temporary.path}/link.txt').exists(), isTrue);
  });

  test('an injected app-files directory is isolated from its parent', () async {
    final documents = await Directory.systemTemp.createTemp('private-agent-docs-');
    addTearDown(() async {
      if (await documents.exists()) await documents.delete(recursive: true);
    });
    final appFiles = Directory('${documents.path}/agent_files');
    final isolated = FileService(directoryProvider: () async => appFiles);

    await isolated.writeText('safe.txt', 'private');
    await File('${documents.path}/other.txt').writeAsString('not private');
    expect(await isolated.listFiles(), <String>['safe.txt']);
    await expectLater(isolated.readText('../other.txt'), throwsA(isA<FileServiceException>()));
  });

  test('supports nested files and recursive listing', () async {
    await service.writeText('sub/note.txt', 'ok');
    expect(await service.listFiles(), <String>['sub/note.txt']);
    expect(await service.readText('sub/note.txt'), 'ok');
  });
}
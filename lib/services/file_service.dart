import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Thrown when a requested file name or operation is not allowed.
class FileServiceException implements Exception {
  FileServiceException(this.message);

  final String message;

  @override
  String toString() => 'FileServiceException: $message';
}

class FileSizeLimitException extends FileServiceException {
  FileSizeLimitException(this.limit)
      : super('The file exceeds the configured ${limit}-byte limit.');

  final int limit;
}

typedef FileServiceDirectoryProvider = Future<Directory> Function();

/// Provides access only to files below the application's private directory.
class FileService {
  FileService({
    Directory? rootDirectory,
    FileServiceDirectoryProvider? directoryProvider,
    this.maxReadBytes = 1024 * 1024,
    this.maxWriteBytes = 1024 * 1024,
  })  : assert(maxReadBytes > 0),
        assert(maxWriteBytes > 0),
        assert(rootDirectory == null || directoryProvider == null),
        _directoryProvider = directoryProvider ??
            (rootDirectory == null
                ? _defaultDirectoryProvider
                : () async => rootDirectory!);

  final int maxReadBytes;
  final int maxWriteBytes;
  final FileServiceDirectoryProvider _directoryProvider;

  static Future<Directory> _defaultDirectoryProvider() async {
    final documents = await getApplicationDocumentsDirectory();
    final agentFiles = Directory('${documents.path}/agent_files');
    if (await FileSystemEntity.type(agentFiles.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileServiceException('The private files directory cannot be a symlink.');
    }
    await agentFiles.create(recursive: true);
    return agentFiles;
  }

  Future<Directory> _root() async => _directoryProvider();

  /// Lists files in the private directory. Returned paths use `/` separators.
  Future<List<String>> listFiles({bool recursive = true}) async {
    final root = await _root();
    if (!await root.exists()) return <String>[];

    final result = <String>[];
    await for (final entity in root.list(recursive: recursive, followLinks: false)) {
      if (entity is File) {
        result.add(_relativePath(root.path, entity.path));
      }
    }
    result.sort();
    return result;
  }

  /// Reads a UTF-8 file, refusing files larger than [maxReadBytes].
  Future<String> readText(String relativePath) async {
    final file = await _fileInsideRoot(relativePath);
    final bytes = await _readUpToLimit(file, maxReadBytes);
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw FileServiceException('The file is not valid UTF-8.');
    }
  }

  /// Writes UTF-8 text, refusing content larger than [maxWriteBytes].
  Future<void> writeText(String relativePath, String text) async {
    final file = await _fileInsideRoot(relativePath, forWrite: true);
    final bytes = utf8.encode(text);
    if (bytes.length > maxWriteBytes) {
      throw FileSizeLimitException(maxWriteBytes);
    }
    if (await file.exists() && await FileSystemEntity.isDirectory(file.path)) {
      throw FileServiceException('Directories cannot be written as files.');
    }
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  /// Deletes a regular file only; directories and unsafe paths are rejected.
  Future<void> delete(String relativePath) async {
    final file = await _fileInsideRoot(relativePath);
    final rawType = await FileSystemEntity.type(file.path, followLinks: false);
    if (rawType == FileSystemEntityType.link) {
      throw FileServiceException('Symlink targets cannot be deleted.');
    }
    final type = await FileSystemEntity.type(file.path, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      throw FileServiceException('The file does not exist.');
    }
    if (type != FileSystemEntityType.file) {
      throw FileServiceException('Only regular files can be deleted.');
    }
    await file.delete();
  }

  Future<File> _fileInsideRoot(String value, {bool forWrite = false}) async {
    final relative = _validateRelativePath(value);
    final root = await _root();
    await root.create(recursive: true);
    final rootCanonical = await root.resolveSymbolicLinks();
    final file = File('${root.path}/$relative');

    if (await file.exists()) {
      final canonical = await file.resolveSymbolicLinks();
      _ensureContained(rootCanonical, canonical);
      return file;
    }

    // For a new file, validate the canonical parent as well. This prevents a
    // pre-existing symlinked directory from escaping the private directory.
    final parent = file.parent;
    if (forWrite) await parent.create(recursive: true);
    final parentCanonical = await parent.resolveSymbolicLinks();
    _ensureContained(rootCanonical, parentCanonical);
    return file;
  }

  String _validateRelativePath(String value) {
    if (value.isEmpty || value.contains('\u0000') || value.contains('\\') ||
        value.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(value)) {
      throw FileServiceException('Invalid private file path.');
    }
    final segments = value.split('/');
    if (segments.any((segment) => segment.isEmpty || segment == '.' || segment == '..')) {
      throw FileServiceException('Path traversal is not allowed.');
    }
    return segments.join('/');
  }

  void _ensureContained(String root, String candidate) {
    final rootPath = _normalise(root);
    final candidatePath = _normalise(candidate);
    if (candidatePath != rootPath &&
        !candidatePath.startsWith('$rootPath/')) {
      throw FileServiceException('Path is outside the private directory.');
    }
  }

  String _normalise(String path) =>
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  String _relativePath(String root, String file) {
    final prefix = _normalise(root);
    final relative = file.startsWith('$prefix/')
        ? file.substring(prefix.length + 1)
        : file;
    return relative.replaceAll('\\', '/');
  }

  Future<List<int>> _readUpToLimit(File file, int limit) async {
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > limit) {
        throw FileSizeLimitException(limit);
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }
}
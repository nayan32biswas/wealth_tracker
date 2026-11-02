import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:wealthtracker/data/device_files.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('wt_files'));
  tearDown(() => dir.delete(recursive: true));

  File file(String name) => File('${dir.path}/$name')..createSync(recursive: true);

  test('removes earlier exports and the share copies, nothing else', () {
    final exports = [
      file('wealthtracker-2026-09-01.sqlite'),
      file('wealthtracker-2026-09-01.wtbackup'),
      file('share_plus/wealthtracker-2026-09-01.sqlite'),
    ];
    final others = [file('restore.sqlite'), file('file_picker/wealthtracker-2026-09-01.csv')];

    clearExportsIn(dir.path);

    expect(exports.where((f) => f.existsSync()), isEmpty);
    expect(others.every((f) => f.existsSync()), isTrue);
  });

  test('works when nothing was shared yet', () {
    expect(() => clearExportsIn(dir.path), returnsNormally);
  });

  group('picking a file', () {
    late _FakePicker picker;
    final original = FilePickerPlatform.instance;

    setUp(() => FilePickerPlatform.instance = picker = _FakePicker());
    tearDown(() => FilePickerPlatform.instance = original);

    test("returns the file's bytes and removes the picker's own copy", () async {
      picker.files = [
        _BytesFile('backup.wtbackup', Uint8List.fromList([1, 2, 3])),
      ];

      expect(await DeviceFiles().pickFile(), [1, 2, 3]);
      expect(picker.cleared, isTrue);
    });

    test('cancelling returns nothing', () async {
      expect(await DeviceFiles().pickFile(), isNull);
      expect(picker.cleared, isFalse);
    });
  });

  group('sharing a file', () {
    // SharePlus keeps the platform it first sees, so one fake serves the group.
    final share = _FakeShare();
    final original = SharePlatform.instance;

    setUpAll(() => SharePlatform.instance = share);
    setUp(share.sent.clear);
    tearDownAll(() => SharePlatform.instance = original);

    test('an encrypted backup goes as plain binary, so apps that hide unknown types still take it', () async {
      await DeviceFiles().share('${dir.path}/wealthtracker-2026-09-01.wtbackup');

      final sent = share.sent.single.files!.single;
      expect(sent.path, endsWith('.wtbackup'));
      expect(sent.mimeType, 'application/octet-stream');
    });

    test('other files keep their own type', () async {
      await DeviceFiles().share('${dir.path}/wealthtracker-2026-09-01.csv');

      expect(share.sent.single.files!.single.mimeType, isNull);
    });
  });

  group('the temporary folder', () {
    final original = PathProviderPlatform.instance;

    setUp(() => PathProviderPlatform.instance = _FakePaths(dir.path));
    tearDown(() => PathProviderPlatform.instance = original);

    test("is the phone's temporary folder", () async {
      expect(await DeviceFiles().tempDirectory(), dir.path);
    });

    test('clearing exports empties it of earlier exports', () async {
      final export = file('wealthtracker-2026-09-01.sqlite');
      final other = file('restore.sqlite');

      await DeviceFiles().clearExports();

      expect(export.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
    });
  });
}

class _FakePicker extends FilePickerPlatform with MockPlatformInterfaceMixin {
  List<PlatformFile> files = [];
  bool cleared = false;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    dynamic Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => files;

  @override
  Future<void> clearTemporaryFiles() async => cleared = true;
}

/// A picked file held in memory, like an Android content:// file.
final class _BytesFile extends PlatformFile {
  _BytesFile(this.name, this.bytes);

  @override
  final String name;
  final Uint8List bytes;

  @override
  Uri get uri => Uri.parse('content://picked/$name');

  @override
  XFile get xFile => XFile.fromData(bytes, name: name);

  @override
  int? lengthSync() => bytes.length;

  @override
  Future<int?> length() async => bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _FakeShare extends SharePlatform with MockPlatformInterfaceMixin {
  final sent = <ShareParams>[];

  @override
  Future<ShareResult> share(ShareParams params) async {
    sent.add(params);
    return const ShareResult('done', ShareResultStatus.success);
  }
}

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.temp);

  final String temp;

  @override
  Future<String?> getTemporaryPath() async => temp;
}

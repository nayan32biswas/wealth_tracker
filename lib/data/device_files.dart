import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/repositories/repositories.dart';

const _androidDownloads = 'content://com.android.externalstorage.documents/document/primary%3ADownload';

class DeviceFiles implements FileGateway {
  // Reads bytes rather than a path: on Android a picked file is often a
  // content:// link with no file path. The picker keeps its own copy in the
  // cache, which may be an unencrypted backup, so that copy is removed.
  @override
  Future<Uint8List?> pickFile() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return null;
    final bytes = await files.first.readAsBytes();
    await FilePicker.clearTemporaryFiles();
    return bytes;
  }

  // Some share targets hide files of a type they don't know. Encrypted backups
  // are sent as plain binary so Drive, mail and chat apps still accept them.
  @override
  Future<void> share(String path) {
    final mimeType = path.endsWith('.wtbackup') ? 'application/octet-stream' : null;
    return SharePlus.instance.share(ShareParams(files: [XFile(path, mimeType: mimeType)]));
  }

  // The phone's own "save as" screen, so no storage permission is needed. On
  // Android it opens at Downloads; the user can still pick another folder.
  // On iOS the plugin first copies the file into the temp folder, and that
  // copy may be an unencrypted backup, so it is removed afterwards.
  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    try {
      final saved = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        initialDirectory: Platform.isAndroid ? _androidDownloads : null,
      );
      return saved != null;
    } on PlatformException {
      throw const RuleViolation('Could not open the save screen. Try Share instead.');
    } finally {
      await FilePicker.clearTemporaryFiles();
    }
  }

  @override
  Future<String> tempDirectory() async => (await getTemporaryDirectory()).path;

  @override
  Future<void> clearExports() async => clearExportsIn(await tempDirectory());
}

/// A shared file can't be deleted right after the share sheet closes: the
/// app that received it may still be reading it. So leftovers are removed
/// before the next export and when the app starts. share_plus keeps its own
/// copy in a subfolder until its next share, so that copy goes too.
void clearExportsIn(String tempDir) {
  for (final dir in [Directory(tempDir), Directory(p.join(tempDir, 'share_plus'))]) {
    if (!dir.existsSync()) continue;
    for (final file in dir.listSync().whereType<File>()) {
      if (p.basename(file.path).startsWith(exportFilePrefix)) file.deleteSync();
    }
  }
}

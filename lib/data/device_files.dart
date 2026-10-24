import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/repositories/repositories.dart';

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

  @override
  Future<String> tempDirectory() async => (await getTemporaryDirectory()).path;
}

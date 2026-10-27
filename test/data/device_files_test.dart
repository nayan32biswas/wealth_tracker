import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}

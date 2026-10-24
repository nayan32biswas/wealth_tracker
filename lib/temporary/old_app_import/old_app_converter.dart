// TEMPORARY: loads data from the old money app. Nothing outside
// lib/temporary/ may import this; delete the folder (and its tile line in
// settings_screen.dart) once the move to WealthTracker is done.
//
// Same rules as Files/migrate.py, in one step: the old tables are read
// directly, without the clean.sqlite in between.

import 'dart:io';
import 'dart:isolate';

import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../data/db/app_database.dart';
import '../../data/repositories/drift_repositories.dart';
import '../../domain/models/app_settings.dart';
import '../../domain/services/calendar.dart';

/// The old phone kept local times as UTC+06:00.
const oldPhoneOffset = Duration(hours: 6);

/// Old DO_TYPE values. Anything else has no type and is skipped.
const _types = {'0': 'income', '1': 'expense', '3': 'tr_out', '4': 'tr_in'};

/// Old category TYPE value that means income.
const _incomeCategoryType = 0;

typedef Row = Map<String, Object?>;

/// What the old data turned into, ready to write and to show the user.
class OldAppData {
  final groups = <Row>[];
  final assets = <Row>[];
  final categories = <int, Row>{};
  final transactions = <Row>[];

  /// Notable changes, e.g. 'added income category "Food"' → 1.
  final changed = <String, int>{};

  /// Rows left out, by reason, with their old ids.
  final skipped = <String, List<int>>{};

  int count(String type) => transactions.where((t) => t['type'] == type).length;
}

/// Reads the old database at [oldPath] and writes the ledger file at
/// [outPath], off the UI thread.
Future<OldAppData> convertOldApp(String oldPath, String outPath, {required AppSettings settings, required int nowMs}) =>
    Isolate.run(() async {
      final data = readOldApp(oldPath, nowMs: nowMs);
      await writeLedger(outPath, data, settings);
      return data;
    });

/// Reads the old app's database at [path] into WealthTracker rows.
OldAppData readOldApp(String path, {required int nowMs}) {
  final old = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return _read(old, nowMs);
  } on SqliteException catch (e) {
    throw FormatException("This is not the old app's database (${e.message}).");
  } finally {
    old.close();
  }
}

OldAppData _read(Database old, int nowMs) {
  final data = OldAppData();
  int? asInt(Object? v) => v == null || v == '' ? null : num.parse('$v').toInt();
  String name(Object? v) => '${v ?? ''}'.trim();

  final groupIds = <String, int>{};
  final deletedGroups = <int>{};
  for (final r in old.select('SELECT DEVICE_ID, ACC_GROUP_NAME, ORDERSEQ, IS_DEL, USETIME, uid FROM ASSETGROUP')) {
    final id = r['DEVICE_ID'] as int;
    data.groups.add({
      'id': id,
      'name': name(r['ACC_GROUP_NAME']),
      'sort_order': asInt(r['ORDERSEQ']) ?? 0,
      'created_at': asInt(r['USETIME']) ?? nowMs,
    });
    if ((asInt(r['IS_DEL']) ?? 0) != 0) deletedGroups.add(id);
    if (r['uid'] case final String uid) groupIds[uid] = id;
  }

  final assetIds = <String, int>{};
  for (final r in old.select('SELECT ID, NIC_NAME, ORDERSEQ, A_UTIME, uid, groupUid FROM ASSETS')) {
    final id = r['ID'] as int;
    final group = groupIds[r['groupUid']];
    if (group == null) throw FormatException('Account ${r['NIC_NAME']} has no group.');
    data.assets.add({
      'id': id,
      'name': name(r['NIC_NAME']),
      'asset_group_id': group,
      'sort_order': asInt(r['ORDERSEQ']) ?? 0,
      'created_at': asInt(r['A_UTIME']) ?? nowMs,
    });
    if (r['uid'] case final String uid) assetIds[uid] = id;
  }
  // Groups can't be soft-deleted here. A deleted old group is dropped unless
  // an account still sits in it.
  final usedGroups = {for (final a in data.assets) a['asset_group_id']};
  data.groups.removeWhere((g) => deletedGroups.contains(g['id']) && !usedGroups.contains(g['id']));

  // STATUS = 2 rows are not real categories.
  final categoryIds = <String, int>{};
  for (final r in old.select(
    'SELECT ID, NAME, ORDERSEQ, TYPE, C_IS_DEL, C_UTIME, uid FROM ZCATEGORY WHERE COALESCE(STATUS, 0) != 2',
  )) {
    final id = r['ID'] as int;
    data.categories[id] = {
      'id': id,
      'name': name(r['NAME']),
      'sort_order': asInt(r['ORDERSEQ']) ?? 0,
      'type': (asInt(r['TYPE']) ?? 0) == _incomeCategoryType ? 'income' : 'expense',
      'is_deleted': (asInt(r['C_IS_DEL']) ?? 0) != 0 ? 1 : 0,
      'created_at': asInt(r['C_UTIME']) ?? nowMs,
    };
    if (r['uid'] case final String uid) categoryIds[uid] = id;
  }

  void skip(String reason, int id) => (data.skipped[reason] ??= []).add(id);
  void note(String change) => data.changed[change] = (data.changed[change] ?? 0) + 1;

  // The app's form only offers categories of the entry's own type.
  int twinCategory(int id, String type) {
    final source = data.categories[id]!;
    final name = source['name']! as String;
    for (final c in data.categories.values) {
      if (c['type'] == type && (c['name']! as String).toLowerCase() == name.toLowerCase()) return c['id']! as int;
    }
    final twin = data.categories.keys.reduce((a, b) => a > b ? a : b) + 1;
    data.categories[twin] = {
      'id': twin,
      'name': name,
      'sort_order': data.categories.length,
      'type': type,
      'is_deleted': source['is_deleted'],
      'created_at': nowMs,
    };
    note('added $type category "$name"');
    return twin;
  }

  Row entry(Row r, Map<String, Object?> fields) {
    final time = r['time']! as int;
    return {
      'id': r['id'],
      'note': r['note'],
      'time': time,
      'date': dateKey(DateTime.fromMillisecondsSinceEpoch(time, isUtc: true).add(oldPhoneOffset)),
      'fee': 0,
      'to_asset_id': null,
      'category_id': null,
      'created_at': r['created_at'],
      ...fields,
    };
  }

  final transfers = <String?, List<Row>>{};
  for (final r in old.select(
    'SELECT AID, ZCONTENT, ZDATE, DO_TYPE, UTIME, AMOUNT_ACCOUNT, assetUid, ctgUid, txUidTrans FROM INOUTCOME ORDER BY AID',
  )) {
    final time = asInt(r['ZDATE']) ?? nowMs;
    final row = <String, Object?>{
      'id': r['AID'] as int,
      'type': _types['${r['DO_TYPE'] ?? ''}'.trim()],
      'amount': switch (r['AMOUNT_ACCOUNT']) {
        null => 0.0,
        final num n => n.toDouble(),
        final v => double.parse('$v'),
      },
      'asset_id': assetIds[r['assetUid']],
      'category_id': categoryIds[r['ctgUid']],
      'note': name(r['ZCONTENT']).isEmpty ? null : name(r['ZCONTENT']),
      'time': time,
      'created_at': asInt(r['UTIME']) ?? time,
      'uid': r['txUidTrans'],
    };
    final id = row['id']! as int;
    final type = row['type'] as String?;
    final amount = row['amount']! as double;
    if (type == 'tr_out' || type == 'tr_in') {
      (transfers[row['uid'] as String?] ??= []).add(row);
      continue;
    }
    if (type == null) {
      skip('no type', id);
      continue;
    }
    if (amount == 0) {
      skip('zero amount', id);
      continue;
    }
    if (row['asset_id'] == null) {
      skip('unknown account', id);
      continue;
    }
    // Negative income and expense amounts (refunds, corrections) are kept as
    // they were: the app allows them, and the old totals stay the same.
    var category = row['category_id'] as int?;
    if (category != null && data.categories[category]!['type'] != type) category = twinCategory(category, type);
    data.transactions.add(
      entry(row, {
        'type': type,
        'amount': amount < 0 ? -toPaisa(-amount) : toPaisa(amount),
        'asset_id': row['asset_id'],
        'category_id': category,
      }),
    );
  }

  // The old app saves a transfer as two rows sharing a uid: tr_out on the
  // sending account and tr_in on the receiving one. The app keeps one row.
  for (final pair in transfers.values) {
    final outs = pair.where((r) => r['type'] == 'tr_out').toList();
    final ins = pair.where((r) => r['type'] == 'tr_in').toList();
    if (outs.length != 1 ||
        ins.length != 1 ||
        outs.single['amount'] == 0 ||
        outs.single['amount'] != ins.single['amount'] ||
        outs.single['asset_id'] == null ||
        ins.single['asset_id'] == null) {
      for (final r in pair) {
        skip('transfer without one matching out and in row', r['id']! as int);
      }
      continue;
    }
    final (o, i) = (outs.single, ins.single);
    data.transactions.add(
      entry(o, {
        'type': 'transfer',
        'amount': toPaisa((o['amount']! as double).abs()),
        'asset_id': o['asset_id'],
        'to_asset_id': i['asset_id'],
        'note': o['note'] ?? i['note'],
      }),
    );
  }
  return data;
}

/// Taka to whole paisa, rounded half-up on the decimal digits as written,
/// so 650.1 is 65010 and 1.005 is 101, not 100.
int toPaisa(double taka) {
  final text = taka.toString();
  if (text.contains('e')) return (taka * 100).round();
  final [whole, ...rest] = text.split('.');
  final fraction = (rest.isEmpty ? '' : rest.single).padRight(3, '0');
  final paisa = int.parse(whole) * 100 + int.parse(fraction.substring(0, 2));
  return fraction.codeUnitAt(2) >= '5'.codeUnitAt(0) ? paisa + 1 : paisa;
}

/// Writes [data] to a new ledger file at [path] that Restore accepts, with
/// [settings] kept from the current ledger.
Future<void> writeLedger(String path, OldAppData data, AppSettings settings) async {
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
  final db = AppDatabase(NativeDatabase(file));
  try {
    await db.transaction(() async {
      // A new database starts with sample categories and accounts.
      for (final table in ['transaction', 'recurring_rule', 'category', 'asset', 'asset_group', 'setting']) {
        await db.customStatement('DELETE FROM "$table"');
      }
      await db.customStatement('DELETE FROM sqlite_sequence');
      await db.batch((b) {
        void insert(String table, Iterable<Row> rows) {
          for (final row in rows) {
            final columns = [...row.keys, 'updated_at'];
            b.customStatement(
              'INSERT INTO "$table" (${columns.map((c) => '"$c"').join(', ')}) '
              'VALUES (${List.filled(columns.length, '?').join(', ')})',
              [...row.values, row['created_at']],
            );
          }
        }

        insert('asset_group', data.groups);
        insert('asset', data.assets);
        insert('category', data.categories.values);
        insert('transaction', data.transactions);
      });
    });
    await DriftRepositories(db).settings.save(settings);
  } finally {
    await db.close();
  }
}

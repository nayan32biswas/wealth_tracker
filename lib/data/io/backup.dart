import 'package:csv/csv.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:sqlite3/sqlite3.dart';

import '../../domain/models/enums.dart';
import '../../domain/models/transactions.dart';
import '../../domain/repositories/repositories.dart';
import '../../domain/services/calendar.dart';
import '../../domain/services/money.dart';
import '../db/app_database.dart';
import '../repositories/drift_repositories.dart';

const csvColumns = ['date', 'time', 'type', 'amount', 'fee', 'account', 'to_account', 'category', 'note'];

const notOurBackup = 'This is not a Wealth Tracker backup.';

/// Returns why [path] can't be restored, or null when it is a usable backup.
/// A backup from this version must match [schema] exactly (tables, columns):
/// once it replaces the live file, anything else would break the app. A
/// backup from an older version passes here; restore upgrades a copy of it
/// and checks that copy again before it replaces anything.
String? checkBackupFile(String path, {required AppDatabase schema}) {
  try {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      if (db.select('PRAGMA integrity_check').first.values.first != 'ok') return 'The backup file is damaged.';
      final version = db.select('PRAGMA user_version').first.values.first as int;
      if (version > schema.schemaVersion) {
        return 'This backup is from a newer version of Wealth Tracker. Update the app, then restore it.';
      }
      if (version < 1) return notOurBackup;
      if (version < schema.schemaVersion) return null;
      for (final table in schema.allTables) {
        final columns = {for (final r in db.select('PRAGMA table_info("${table.actualTableName}")')) r['name']};
        if (!_sameColumns(columns, table.$columns.map((c) => c.name))) return notOurBackup;
      }
      return null;
    } finally {
      db.close();
    }
  } on SqliteException {
    return notOurBackup;
  }
}

bool _sameColumns(Set<Object?> found, Iterable<String> expected) =>
    found.length == expected.length && expected.every(found.contains);

class DriftBackupService implements BackupService {
  DriftBackupService(this._db, this._repos);

  final AppDatabase _db;
  final DriftRepositories _repos;

  Future<MoneyFormat> get _money async => MoneyFormat.of(await _repos.settings.get());

  @override
  Future<void> exportSqlite(String targetPath) => _db.customStatement('VACUUM INTO ?', [targetPath]);

  @override
  Future<String> exportCsv() async {
    final money = await _money;
    final accounts = {for (final a in await _db.select(_db.assets).get()) a.id: a.name};
    final categories = {for (final c in await _db.select(_db.categories).get()) c.id: c.name};
    final txns = (await _repos.transactions.find(const TransactionQuery())).reversed;
    String two(int n) => '$n'.padLeft(2, '0');
    return csv.encode([
      csvColumns,
      for (final t in txns)
        [
          dateKey(t.dateTime),
          '${two(t.dateTime.hour)}:${two(t.dateTime.minute)}',
          t.type.name,
          money.plain(t.amount),
          money.plain(t.fee),
          accounts[t.assetId] ?? '',
          accounts[t.toAssetId] ?? '',
          categories[t.categoryId] ?? '',
          t.note ?? '',
        ],
    ]);
  }

  @override
  Future<CsvPreview> previewCsv(String text) async {
    final lines = csv.decode(text);
    if (lines.isEmpty || lines.first.map((c) => '$c'.trim()).join(',') != csvColumns.join(',')) {
      return CsvPreview(
        rows: const [],
        errors: ['The first line must be: ${csvColumns.join(',')}'],
        newAccounts: const {},
        newCategories: const {},
      );
    }
    final money = await _money;
    final knownAccounts = (await _accountIds()).keys.toSet();
    final knownCategories = {for (final c in await _repos.categories.all()) _categoryLabel(c.type.name, c.name)};
    final rows = <CsvEntry>[];
    final errors = <String>[];
    final newAccounts = <String>{};
    final newCategories = <String>{};

    for (final (i, line) in lines.skip(1).indexed) {
      final (entry, problem) = _parse([for (final c in line) '$c'.trim()], money);
      if (problem != null) {
        errors.add('Line ${i + 2}: $problem');
        continue;
      }
      rows.add(entry!);
      for (final name in [entry.account, ?entry.toAccount]) {
        if (!knownAccounts.contains(name)) newAccounts.add(name);
      }
      if (entry.category case final name?) {
        final label = _categoryLabel(entry.type.name, name);
        if (!knownCategories.contains(label)) newCategories.add(label);
      }
    }
    return CsvPreview(rows: rows, errors: errors, newAccounts: newAccounts, newCategories: newCategories);
  }

  @override
  Future<void> importCsv(CsvPreview preview) => _db.transaction(() async {
    final accounts = await _accountIds();
    final categories = {for (final c in await _repos.categories.all()) _categoryLabel(c.type.name, c.name): c.id};
    final groups = await _repos.groups.all();
    // New accounts from a CSV go into the first asset group; the user can
    // move them afterwards.
    final targetGroup = groups.firstWhere((g) => !g.isLiability, orElse: () => groups.first).id;

    Future<int> account(String name) async => accounts[name] ??= await _repos.assets.add(name, targetGroup);
    Future<int> category(TransactionType type, String name) async => categories[_categoryLabel(type.name, name)] ??=
        await _repos.categories.add(name, type == TransactionType.income ? CategoryType.income : CategoryType.expense);

    for (final e in preview.rows) {
      await _repos.transactions.save(
        Transaction(
          id: 0,
          type: e.type,
          amount: e.amount,
          fee: e.fee,
          assetId: await account(e.account),
          toAssetId: e.toAccount == null ? null : await account(e.toAccount!),
          categoryId: e.category == null ? null : await category(e.type, e.category!),
          note: e.note,
          dateTime: e.dateTime,
        ),
      );
    }
  });

  // Archived accounts count too, so an import doesn't make a second "Cash".
  // Active ones win when two share a name.
  Future<Map<String, int>> _accountIds() async => {
    for (final a in await (_db.select(_db.assets)..orderBy([(a) => OrderingTerm.desc(a.isArchived)])).get())
      a.name: a.id,
  };

  static String _categoryLabel(String type, String name) => '${type[0].toUpperCase()}${type.substring(1)}: $name';

  static (CsvEntry?, String?) _parse(List<String> f, MoneyFormat money) {
    String at(int i) => i < f.length ? f[i] : '';
    final date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(at(0));
    final time = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(at(1));
    final type = TransactionType.values.where((t) => t.name == at(2)).firstOrNull;
    final negative = at(3).trim().startsWith('-');
    final magnitude = money.parse(negative ? at(3).trim().substring(1) : at(3));
    final amount = magnitude == null ? null : (negative ? -magnitude : magnitude);
    final fee = at(4).isEmpty ? 0 : money.parse(at(4));
    final (account, toAccount, category, note) = (at(5), at(6), at(7), at(8));

    if (date == null || !_isRealDate(date)) return (null, 'date must look like 2026-09-23');
    if (time == null || int.parse(time[1]!) > 23 || int.parse(time[2]!) > 59) {
      return (null, 'time must look like 13:05');
    }
    if (type == null) return (null, 'type must be income, expense or transfer');
    if (amount == null || amount == 0) return (null, 'amount is not a valid number');
    if (type == TransactionType.transfer && amount < 0) return (null, "a transfer can't be negative");
    if (fee == null) return (null, 'fee is not a valid number');
    if (account.isEmpty) return (null, 'account is missing');
    if (type == TransactionType.transfer && toAccount.isEmpty) return (null, 'a transfer needs to_account');
    if (type == TransactionType.transfer && toAccount == account) {
      return (null, 'a transfer needs two different accounts');
    }
    if (type == TransactionType.income && fee > amount.abs()) return (null, "the fee can't be more than the amount");
    if (type != TransactionType.transfer && category.isEmpty) return (null, 'income and expense need a category');

    return (
      CsvEntry(
        type: type,
        amount: amount,
        fee: fee,
        dateTime: DateTime(
          int.parse(date[1]!),
          int.parse(date[2]!),
          int.parse(date[3]!),
          int.parse(time[1]!),
          int.parse(time[2]!),
        ),
        account: account,
        toAccount: type == TransactionType.transfer ? toAccount : null,
        category: type == TransactionType.transfer ? null : category,
        note: note.isEmpty ? null : note,
      ),
      null,
    );
  }

  static bool _isRealDate(RegExpMatch m) {
    final (y, mo, d) = (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    final date = DateTime(y, mo, d);
    return date.year == y && date.month == mo && date.day == d;
  }
}

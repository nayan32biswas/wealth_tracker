import 'package:csv/csv.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../domain/models/accounts.dart';
import '../../domain/models/categories.dart';
import '../../domain/models/enums.dart';
import '../../domain/models/ledger_import.dart';
import '../../domain/models/transactions.dart';
import '../../domain/repositories/repositories.dart';
import '../../domain/services/calendar.dart';
import '../../domain/services/money.dart';
import '../db/app_database.dart';
import '../repositories/drift_repositories.dart';
import 'ledger_import.dart';

/// Written in this order on export. Import finds them by name, in any order.
/// `linked_to` is set on a fee: the line number of the entry it belongs to,
/// always an earlier line.
const csvColumns = ['date', 'time', 'type', 'amount', 'account', 'to_account', 'category', 'note', 'linked_to'];
const _requiredCsvColumns = ['date', 'time', 'type', 'amount', 'account'];

const notOurBackup = 'This is not a Wealth Tracker backup.';

/// Why [path] can't be restored, or null when it can.
String? checkBackupFile(String path, {required int schemaVersion}) {
  try {
    readBackupFile(path, schemaVersion: schemaVersion);
    return null;
  } on RuleViolation catch (e) {
    return e.message;
  }
}

/// Reads a backup made by this version or any older one. Columns are read
/// by name: one this version doesn't know is skipped and a missing one gets
/// its default, so adding or removing a column never breaks an old backup.
/// When a column changes meaning, convert it here and add a backup from the
/// old version to `test/fixtures/backups/`. Throws [RuleViolation] when the
/// file can't be used.
LedgerImport readBackupFile(String path, {required int schemaVersion}) {
  final Database file;
  try {
    file = sqlite3.open(path, mode: OpenMode.readOnly);
  } on SqliteException {
    throw const RuleViolation(notOurBackup);
  }
  try {
    if (file.select('PRAGMA integrity_check').first.values.first != 'ok') {
      throw const RuleViolation('The backup file is damaged.');
    }
    final version = file.select('PRAGMA user_version').first.values.first as int;
    if (version > schemaVersion) {
      throw const RuleViolation(
        'This backup is from a newer version of Wealth Tracker. Update the app, then restore it.',
      );
    }
    if (version < 1) throw const RuleViolation(notOurBackup);
    final data = _readLedger(file);
    // Found here, the problem is shown before anything is replaced. Found
    // during the restore, the screen that could show it is already gone.
    if (ledgerProblem(data) case final problem?) throw RuleViolation("This backup can't be restored. $problem");
    return data;
  } on RuleViolation {
    rethrow;
  } on Object {
    // A missing table or required column, or a value of the wrong kind.
    throw const RuleViolation(notOurBackup);
  } finally {
    file.close();
  }
}

LedgerImport _readLedger(Database file) {
  List<_Fields> rows(String table) => [for (final r in file.select('SELECT * FROM "$table"')) _Fields(r)];
  DateTime day(String text) => DateTime.parse(text);

  final categories = rows('category');
  final rules = rows('recurring_rule');
  return LedgerImport(
    groups: [
      for (final r in rows('asset_group'))
        AssetGroup(
          id: r.need('id'),
          name: r.need('name'),
          type: GroupType.values.byName(r.or('type', 'asset')),
          order: r.or('sort_order', 0),
        ),
    ],
    accounts: [
      for (final r in rows('asset'))
        Asset(
          id: r.need('id'),
          name: r.need('name'),
          groupId: r.need('asset_group_id'),
          order: r.or('sort_order', 0),
          initialBalance: r.or('initial_balance', 0),
          isArchived: r.flag('is_archived', false),
        ),
    ],
    categories: [
      for (final r in categories)
        Category(
          id: r.need('id'),
          name: r.need('name'),
          type: CategoryType.values.byName(r.need('type')),
          order: r.or('sort_order', 0),
        ),
    ],
    deletedCategoryIds: {
      for (final r in categories)
        if (r.flag('is_deleted', false)) r.need<int>('id'),
    },
    rules: [
      for (final r in rules)
        RecurringRule(
          id: r.need('id'),
          type: TransactionType.values.byName(r.need('type')),
          amount: r.need('amount'),
          assetId: r.need('asset_id'),
          toAssetId: r.maybe('to_asset_id'),
          categoryId: r.maybe('category_id'),
          note: r.maybe('note'),
          frequency: Frequency.values.byName(r.need('frequency')),
          interval: r.or('interval', 1),
          startDate: day(r.need('start_date')),
          endDate: switch (r.maybe<String>('end_date')) {
            final d? => day(d),
            null => null,
          },
          nextDate: day(r.need('next_date')),
          isActive: r.flag('is_active', true),
        ),
    ],
    deletedRuleIds: {
      for (final r in rules)
        if (r.flag('is_deleted', false)) r.need<int>('id'),
    },
    transactions: [
      for (final r in rows('transaction'))
        Transaction(
          id: r.need('id'),
          type: TransactionType.values.byName(r.need('type')),
          amount: r.need('amount'),
          assetId: r.need('asset_id'),
          toAssetId: r.maybe('to_asset_id'),
          categoryId: r.maybe('category_id'),
          note: r.maybe('note'),
          dateTime: DateTime.fromMillisecondsSinceEpoch(r.need('time')),
          recurringRuleId: r.maybe('recurring_rule_id'),
          parentId: r.maybe('parent_id'),
        ),
    ],
    settings: {for (final r in rows('setting')) r.need<String>('key'): r.need<String>('value')},
  );
}

/// One row of a backup, read by column name. A column the row doesn't have
/// reads as null.
extension type _Fields(Row row) {
  T need<T>(String column) => row[column] as T;

  T? maybe<T>(String column) => row[column] as T?;

  T or<T>(String column, T fallback) => maybe<T>(column) ?? fallback;

  bool flag(String column, bool fallback) => switch (maybe<int>(column)) {
    null => fallback,
    final v => v != 0,
  };
}

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
    // Oldest first, ties by id: a fee is saved after its entry, so the
    // entry's line always comes first.
    final txns = (await _repos.transactions.find(const TransactionQuery())).reversed.toList();
    final lines = {for (final (i, t) in txns.indexed) t.id: i + 2};
    String two(int n) => '$n'.padLeft(2, '0');
    return csv.encode([
      csvColumns,
      for (final t in txns)
        [
          dateKey(t.dateTime),
          '${two(t.dateTime.hour)}:${two(t.dateTime.minute)}',
          t.type.name,
          money.plain(t.amount),
          accounts[t.assetId] ?? '',
          accounts[t.toAssetId] ?? '',
          categories[t.categoryId] ?? '',
          t.note ?? '',
          lines[t.parentId] ?? '',
        ],
    ]);
  }

  @override
  Future<CsvPreview> previewCsv(String text) async {
    final lines = csv.decode(text);
    // Columns are found by name: any order, extra ones ignored, optional ones
    // may be left out.
    final header = {
      for (final (i, c) in (lines.firstOrNull ?? const []).indexed)
        '$c'.replaceAll('\uFEFF', '').trim().toLowerCase(): i,
    };
    if (!_requiredCsvColumns.every(header.containsKey)) {
      return CsvPreview(
        rows: const [],
        errors: ['The first line must name these columns: ${csvColumns.join(',')}'],
        newAccounts: const {},
        newCategories: const {},
      );
    }
    final money = await _money;
    final knownAccounts = (await accountIdsByName(_db)).keys.toSet();
    final knownCategories = (await categoryIdsByKey(_db)).keys.toSet();
    final rows = <CsvEntry>[];
    final errors = <String>[];
    final newAccounts = <String>{};
    final newCategories = <String>{};

    final byLine = <int, CsvEntry>{};
    final feeOwners = <int>{};
    for (final (i, line) in lines.skip(1).indexed) {
      String field(String column) => switch (header[column]) {
        final at? when at < line.length => '${line[at]}'.trim(),
        _ => '',
      };
      final (entry, parseProblem) = _parse(field, money, i + 2);
      final problem = parseProblem ?? _linkProblem(entry!, byLine, feeOwners);
      if (problem != null) {
        errors.add('Line ${i + 2}: $problem');
        continue;
      }
      rows.add(entry!);
      byLine[entry.line] = entry;
      for (final name in [entry.account, ?entry.toAccount]) {
        if (!knownAccounts.contains(name)) newAccounts.add(name);
      }
      if (entry.category case final name?) {
        final type = _categoryType(entry.type);
        if (!knownCategories.contains(categoryKey(type, name))) {
          newCategories.add('${type == CategoryType.income ? 'Income' : 'Expense'}: $name');
        }
      }
    }
    return CsvPreview(rows: rows, errors: errors, newAccounts: newAccounts, newCategories: newCategories);
  }

  @override
  Future<void> importCsv(CsvPreview preview) {
    final accounts = <String, int>{};
    final categories = <String, Category>{};
    int account(String name) => accounts[name] ??= accounts.length + 1;
    int category(TransactionType type, String name) => (categories[categoryKey(_categoryType(type), name)] ??= Category(
      id: categories.length + 1,
      name: name,
      type: _categoryType(type),
    )).id;

    final transactions = [
      for (final e in preview.rows)
        Transaction(
          id: e.line,
          parentId: e.linkedTo,
          type: e.type,
          amount: e.amount,
          assetId: account(e.account),
          toAssetId: e.toAccount == null ? null : account(e.toAccount!),
          categoryId: e.category == null ? null : category(e.type, e.category!),
          note: e.note,
          dateTime: e.dateTime,
        ),
    ];
    return _repos.importLedger(
      LedgerImport(
        accounts: [
          for (final MapEntry(key: name, value: id) in accounts.entries) Asset(id: id, name: name, groupId: 0),
        ],
        categories: categories.values.toList(),
        transactions: transactions,
      ),
    );
  }

  static String? _linkProblem(CsvEntry e, Map<int, CsvEntry> byLine, Set<int> feeOwners) {
    final owner = e.linkedTo;
    if (owner == null) return null;
    if (owner < 2 || owner >= e.line) return 'linked_to must be the line number of an earlier entry';
    final main = byLine[owner];
    // That line has its own error, which already blocks the file.
    if (main == null) return null;
    if (main.linkedTo != null) return 'linked_to points to a line that is itself a fee';
    if (e.type != TransactionType.expense) return 'only an expense can be linked as a fee';
    // Saving the entry later rewrites its fee to match, so a mismatch here
    // would change quietly on the next edit.
    if (e.account != main.account || e.dateTime != main.dateTime || e.note != main.note) {
      return 'a fee must have the same account, date, time and note as line $owner';
    }
    if (!feeOwners.add(owner)) return 'line $owner already has a fee';
    return null;
  }

  static CategoryType _categoryType(TransactionType type) =>
      type == TransactionType.income ? CategoryType.income : CategoryType.expense;

  static (CsvEntry?, String?) _parse(String Function(String column) field, MoneyFormat money, int line) {
    final date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(field('date'));
    final time = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(field('time'));
    final type = TransactionType.values.where((t) => t.name == field('type')).firstOrNull;
    final rawAmount = field('amount');
    final negative = rawAmount.startsWith('-');
    final magnitude = money.parse(negative ? rawAmount.substring(1) : rawAmount);
    final amount = magnitude == null ? null : (negative ? -magnitude : magnitude);
    final (account, toAccount, category, note) = (
      field('account'),
      field('to_account'),
      field('category'),
      field('note'),
    );

    if (date == null || !_isRealDate(date)) return (null, 'date must look like 2026-09-23');
    if (time == null || int.parse(time[1]!) > 23 || int.parse(time[2]!) > 59) {
      return (null, 'time must look like 13:05');
    }
    if (type == null) return (null, 'type must be income, expense or transfer');
    if (amount == null) return (null, 'amount is not a valid number');
    if (type == TransactionType.transfer && amount < 0) return (null, "a transfer can't be negative");
    if (account.isEmpty) return (null, 'account is missing');
    if (type == TransactionType.transfer && toAccount.isEmpty) return (null, 'a transfer needs to_account');
    if (type == TransactionType.transfer && toAccount == account) {
      return (null, 'a transfer needs two different accounts');
    }
    if (type != TransactionType.transfer && category.isEmpty) return (null, 'income and expense need a category');
    final linkedText = field('linked_to');
    final linkedTo = int.tryParse(linkedText);
    if (linkedText.isNotEmpty && linkedTo == null) return (null, 'linked_to must be a line number');

    return (
      CsvEntry(
        type: type,
        amount: amount,
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
        line: line,
        linkedTo: linkedTo,
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

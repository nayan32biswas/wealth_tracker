import 'dart:typed_data';

import '../models/accounts.dart';
import '../models/app_settings.dart';
import '../models/categories.dart';
import '../models/enums.dart';
import '../models/ledger_import.dart';
import '../models/transactions.dart';

class RuleViolation implements Exception {
  const RuleViolation(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class AssetGroupRepository {
  Stream<List<AssetGroup>> watchAll();
  Future<List<AssetGroup>> all();
  Future<int> add(String name, GroupType type);
  Future<void> update(AssetGroup group);
  Future<void> reorder(List<int> idsInOrder);

  /// Throws [RuleViolation] while the group has any account, archived ones
  /// included: an archived account still needs its group to count as an
  /// asset or a liability.
  Future<void> remove(int id);
}

abstract interface class AssetRepository {
  /// Accounts in use, without archived ones. Pickers and lists show these.
  Stream<List<Asset>> watchAll();
  Future<List<Asset>> all();
  Stream<List<Asset>> watchArchived();

  /// Id to name for every account, archived ones included, so old
  /// transactions can still show where the money went.
  Stream<Map<int, String>> watchNames();
  Future<int> add(String name, int groupId, {int initialBalance = 0});
  Future<void> update(Asset asset);
  Future<void> reorder(List<int> idsInOrder);

  Future<int> usage(int id);

  /// Deletes the account when nothing uses it; otherwise archives it, since
  /// its entries keep it in the books. Decided in one database transaction,
  /// so a count taken earlier can't make it fail. Returns true when deleted.
  /// Throws [RuleViolation] while a recurring rule still uses it.
  Future<bool> remove(int id);

  /// Hides the account from pickers and lists. Throws [RuleViolation] while a
  /// recurring rule still uses it.
  Future<void> archive(int id);

  Future<void> unarchive(int id);
}

abstract interface class CategoryRepository {
  Stream<List<Category>> watchAll();

  /// Includes removed categories, like [AssetRepository.watchNames].
  Stream<Map<int, String>> watchNames();
  Future<List<Category>> all();
  Future<int> add(String name, CategoryType type);
  Future<void> update(Category category);
  Future<void> reorder(List<int> idsInOrder);
  Future<int> usage(int id);
  Future<void> remove(int id);
  Future<void> merge(int fromId, int intoId);
  Stream<List<Category>> watchDeleted();

  /// Brings a category marked as deleted back, at the end of the list.
  Future<void> restore(int id);
}

abstract interface class TransactionRepository {
  Stream<List<Transaction>> watch(TransactionQuery query);
  Future<List<Transaction>> find(TransactionQuery query);

  /// Inserts when `id == 0`, otherwise updates. Returns the id. In the same
  /// database transaction the entry's fee row is added, updated or removed to
  /// match [fee]: pass the fee again when editing, or it is removed. Throws
  /// [RuleViolation] for a fee row itself, which changes only with its entry.
  Future<int> save(Transaction transaction, {Fee? fee});

  /// Deletes the entry and its fee.
  Future<void> delete(int id);
  Future<Transaction?> byId(int id);
  Future<Transaction?> feeOf(int parentId);

  /// The fee category to offer for [main]: the one last used on an entry with
  /// the same category (or, for a transfer, the same two accounts), else the
  /// last fee category used at all.
  Future<int?> lastFeeCategory(Transaction main);
  Future<bool> hasAny();

  /// Sum of all transaction effects per account, without opening balances.
  Stream<Map<int, int>> watchBalanceDeltas();
  Stream<List<MonthlyFlow>> watchMonthlyFlows();

  /// Income and expense of every entry that matches [query], ignoring its
  /// sort and limit. Transfers count as neither.
  Stream<({int income, int expense})> watchTotals(TransactionQuery query);

  /// Notes used on or after [since] that start with [text] or have a word
  /// that does, ignoring case. Notes used with [categoryId] come first, then
  /// the most used, then the most recent. A note equal to [text] is left out.
  Future<List<String>> noteSuggestions({String text = '', int? categoryId, required DateTime since, int limit = 8});
}

abstract interface class RecurringRuleRepository {
  Stream<List<RecurringRule>> watchAll();
  Future<List<RecurringRule>> active();
  Future<int> save(RecurringRule rule);
  Future<void> remove(int id);

  /// Creates one transaction per date and moves the rule's next date,
  /// all in one database transaction. Dates already created are skipped.
  Future<void> applyOccurrences(RecurringRule rule, List<DateTime> dates, DateTime nextDate);
}

abstract interface class SettingsRepository {
  Stream<AppSettings> watch();
  Future<AppSettings> get();
  Future<void> save(AppSettings settings);
}

abstract interface class Repositories {
  AssetGroupRepository get groups;
  AssetRepository get assets;
  CategoryRepository get categories;
  TransactionRepository get transactions;
  RecurringRuleRepository get recurring;
  SettingsRepository get settings;

  /// Puts back the starter accounts and categories of a fresh install and
  /// removes all transactions and recurring rules. Settings stay.
  Future<void> resetToStarter();

  /// Runs [action] as one database transaction: all of it is saved, or none.
  Future<T> inTransaction<T>(Future<T> Function() action);

  /// Saves [data] in one database transaction, or nothing when it breaks a
  /// rule ([RuleViolation]). Database restore, CSV import and demo data all
  /// come in here. With [replace] the ledger is emptied first and the
  /// source's list order is kept. Otherwise accounts and categories already
  /// here with the same name are reused, and new ones go to the end.
  Future<void> importLedger(LedgerImport data, {bool replace = false});
}

/// One valid CSV line, with accounts and categories still given by name.
class CsvEntry {
  const CsvEntry({
    required this.type,
    required this.amount,
    required this.dateTime,
    required this.account,
    this.toAccount,
    this.category,
    this.note,
    this.line = 0,
    this.linkedTo,
  });

  final TransactionType type;
  final int amount;
  final DateTime dateTime;
  final String account;
  final String? toAccount;
  final String? category;
  final String? note;

  /// Line number in the file, the header being line 1.
  final int line;

  /// For a fee: the [line] of the entry it belongs to.
  final int? linkedTo;
}

class CsvPreview {
  const CsvPreview({required this.rows, required this.errors, required this.newAccounts, required this.newCategories});

  final List<CsvEntry> rows;
  final List<String> errors;
  final Set<String> newAccounts;

  /// Shown as "Expense: Pets".
  final Set<String> newCategories;

  /// All or nothing: one bad line blocks the whole file.
  bool get canImport => errors.isEmpty && rows.isNotEmpty;
}

abstract interface class BackupService {
  Future<void> exportSqlite(String targetPath);
  Future<String> exportCsv();
  Future<CsvPreview> previewCsv(String text);

  /// Adds every row in one database transaction, creating missing accounts
  /// and categories.
  Future<void> importCsv(CsvPreview preview);
}

/// Every exported file name starts with this, so leftovers can be found.
const exportFilePrefix = 'wealthtracker-';

/// Picking and sharing files through the phone's own screens.
abstract interface class FileGateway {
  Future<Uint8List?> pickFile();
  Future<void> share(String path);

  /// Lets the user pick a folder for [bytes]. False when they cancel.
  Future<bool> save(String fileName, Uint8List bytes);

  Future<String> tempDirectory();

  /// Deletes files left by earlier exports, some of them unencrypted backups.
  Future<void> clearExports();
}

/// Replaces the whole ledger with a backup file.
abstract interface class DatabaseRestorer {
  /// Why the file can't be restored, or null when it can.
  String? check(String path);

  /// Swaps the live database for [path] and reloads the app's data. Call it
  /// only after [check] accepted the same file.
  Future<void> restore(String path);
}

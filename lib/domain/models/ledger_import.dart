import 'accounts.dart';
import 'categories.dart';
import 'transactions.dart';

/// Data to add to the ledger in one go: from a database backup, a CSV file
/// or demo data. One writer saves all of them (`Repositories.importLedger`),
/// so every way in follows the same rules.
///
/// Ids are the source's own. They only link the rows of this import to each
/// other (a fee to its entry through `parentId`, too) and are replaced when
/// saved; entries that nothing links to may all have id 0. An account whose `groupId` is not in
/// [groups] (0 for CSV and demo data) goes into the first asset group.
class LedgerImport {
  const LedgerImport({
    this.groups = const [],
    this.accounts = const [],
    this.categories = const [],
    this.rules = const [],
    this.transactions = const [],
    this.deletedCategoryIds = const {},
    this.deletedRuleIds = const {},
    this.settings,
  });

  final List<AssetGroup> groups;
  final List<Asset> accounts;
  final List<Category> categories;
  final List<RecurringRule> rules;
  final List<Transaction> transactions;

  /// Removed categories and rules come along because old entries still
  /// point at them.
  final Set<int> deletedCategoryIds;
  final Set<int> deletedRuleIds;

  /// Setting keys and values; null keeps the current settings. Keys this
  /// version doesn't know are dropped and missing ones get their defaults.
  final Map<String, String>? settings;
}

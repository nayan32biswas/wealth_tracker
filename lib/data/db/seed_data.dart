import 'package:drift/drift.dart';

import '../../domain/models/app_settings.dart';
import 'app_database.dart';

const _groups = [
  ('Cash', 'asset', ['Cash']),
  ('Bank', 'asset', ['Bank Account']),
  ('Mobile Wallet', 'asset', ['Mobile Wallet']),
  ('Card', 'liability', ['Credit Card']),
  ('Loan', 'liability', <String>[]),
];

const _expenseCategories = [
  'Food',
  'Meal',
  'Transport',
  'Utilities',
  'Rent',
  'Shopping',
  'Health',
  'Education',
  'Mobile & Internet',
  'Gift',
  'Bank Charges',
  'Other',
];

const _incomeCategories = ['Salary', 'Bonus', 'Business', 'Interest', 'Gift', 'Other'];

Future<void> seedStarterData(AppDatabase db, int now) async {
  await seedStarterLedger(db, now);
  await db.batch((b) {
    b.insertAll(db.settings, [
      for (final e in const AppSettings().toMap().entries) SettingsCompanion.insert(key: e.key, value: e.value),
    ]);
  });
}

/// The groups, accounts and categories of a fresh install.
Future<void> seedStarterLedger(AppDatabase db, int now) async {
  var assetOrder = 0;
  for (final (i, (name, type, accounts)) in _groups.indexed) {
    final groupId = await db
        .into(db.assetGroups)
        .insert(
          AssetGroupsCompanion.insert(
            name: name,
            type: Value(type),
            sortOrder: Value(i),
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (final account in accounts) {
      await db
          .into(db.assets)
          .insert(
            AssetsCompanion.insert(
              name: account,
              assetGroupId: groupId,
              sortOrder: Value(assetOrder++),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  }

  Future<void> addCategories(List<String> names, String type) async {
    for (final (i, name) in names.indexed) {
      await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(name: name, type: type, sortOrder: Value(i), createdAt: now, updatedAt: now),
          );
    }
  }

  await addCategories(_expenseCategories, 'expense');
  await addCategories(_incomeCategories, 'income');
}

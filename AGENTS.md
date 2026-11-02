# WealthTracker — Agent Instructions

Personal finance app for Android and iOS; all data is local SQLite. Overview, ids and setup: [README.md](README.md).

This folder is its own git repo. Run git commands here, not in the parent folder.

## Stack

- Flutter (stable), Dart
- Drift + `sqlite3` (SQLite)
- Riverpod (state), go_router (navigation)
- fl_chart (charts), local_auth + flutter_secure_storage (app lock)
- crypto + pointycastle (PIN hash, backup encryption)
- share_plus + file_picker + path_provider (import/export), csv, intl

## Architecture rules

Three layers under `lib/`. The UI never talks to the database directly.

- `domain/` — pure Dart models, repository interfaces, services. No Flutter or Drift imports.
- `data/` — Drift tables, repository implementations (query Drift directly), import/export.
- `presentation/` — screens, widgets, Riverpod controllers. Depends on `domain/` only; gets implementations through providers wired in `main.dart`.

## Data rules

- Money is stored as integers in the smallest unit (paisa). Never use `double` for money.
- Transfers are one row (`asset_id` = from, `to_asset_id` = to).
- Balance = initial + income − expense − transfer out + transfer in.
- A transaction has one amount. A charge is its own expense. Typed in the form's fee field, it is saved as an expense linked to the entry (`parent_id`): same account (the From account of a transfer), date and note, edited and deleted with it, at most one per entry. Income with a deduction (TDS, a broker fee) is entered gross with the deduction as its fee, so the account gains what arrived.
- Categories and recurring rules are removed by soft delete (`is_deleted`). Transactions are deleted for real.
- An account with transactions is never deleted, only archived (`is_archived`): hidden from pickers and lists, still counted in every balance and in net worth. Only an account no transaction uses can be deleted. A group can be deleted only when it has no accounts, archived ones included.
- Lists follow the user-set `sort_order` column.
- Database restore, CSV import and demo data all save through one writer, `importLedger` (`data/io/ledger_import.dart`). The backup reader (`readBackupFile`) reads columns by name: unknown ones are skipped, missing ones get defaults, so adding or removing a column never breaks an old backup. When the schema changes, add a backup made by the previous version to `test/fixtures/backups/` with a test in `ledger_store_test.dart`; if a column changes meaning, convert it in `readBackupFile`.
- Until the first public release, change schema v1 in place: no `schemaVersion` bump, no migration. Refresh the snapshot (delete `drift_schemas/app/drift_schema_v1.json`, run `dart run drift_dev make-migrations`) and clear the app's data on test devices.
- After the first release, every schema change bumps `schemaVersion` and ships with a tested migration. Don't use drift's generated migration tests: they break on the `transaction` table name. Rebuild the old version from its exact SQL, open it with the app, and check the data and `validateDatabaseSchema()`.

## Code style

- Keep related code in one file: one file per topic (e.g. all account models, all Drift repositories for setup data), roughly 100–300 lines. Don't create a file per small class; split only when a file grows past ~400 lines.
- Don't write comments that repeat what the code says. Comment only business rules and the reasons behind them.
- Keep the UI simple: no icons on categories or accounts, no user-picked colors.
- Dialogs use `AppDialog` (or `EditDialog`, `confirm`, `pickOne`) from `presentation/widgets/`: an ✕ in the title closes, no Cancel button; at most one secondary action on the left and the main action filled on the right.

## Commands

```
flutter pub get
tool/codegen.sh                 # Drift codegen (build_runner, then dart format)
flutter analyze
flutter test
flutter test integration_test   # on emulator/device
```

Before every commit, `flutter analyze` is clean and `flutter test` is green.

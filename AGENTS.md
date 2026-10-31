# WealthTracker — Agent Instructions

Personal finance app (income, expenses, transfers, accounts, net worth, stats) for Android and iOS. All data is local SQLite. Full plan: `doc/build-plan.md`.

This folder is its own git repo. Run git commands here, not in the parent folder.

## Stack

- Flutter (stable), Dart
- Drift (SQLite), `sqlite3_flutter_libs`
- Riverpod (state), go_router (navigation)
- fl_chart (charts), local_auth + flutter_secure_storage (app lock)
- share_plus + file_picker (import/export), csv, intl

Bundle id: `com.nayanbiswas.wealthtracker`

## Architecture rules

Three layers under `lib/`. The UI never talks to the database directly.

- `domain/` — pure Dart models, repository interfaces, services. No Flutter or Drift imports.
- `data/` — Drift tables, repository implementations (query Drift directly), import/export.
- `presentation/` — screens, widgets, Riverpod controllers. Depends on `domain/` only; gets implementations through providers wired in `main.dart`.

## Data rules

- Money is stored as integers in the smallest unit (paisa). Never use `double` for money.
- Transfers are one row (`asset_id` = from, `to_asset_id` = to). A transfer fee comes off the source account.
- Balance = initial + (income − fee) − (expense + fee) − (transfer out + fee) + transfer in. A fee on income (e.g. tax deducted) is taken off what arrives.
- Percent fees round half-up to the smallest unit.
- Categories and recurring rules are removed by soft delete (`is_deleted`). Transactions are deleted for real.
- An account with transactions is never deleted, only archived (`is_archived`): hidden from pickers and lists, still counted in every balance and in net worth. Only an account no transaction uses can be deleted. A group can be deleted only when it has no accounts, archived ones included.
- Lists follow the user-set `sort_order` column.
- Until the first public release, change schema v1 in place: no `schemaVersion` bump, no migration. Refresh the snapshot (delete `drift_schemas/app/drift_schema_v1.json`, run `dart run drift_dev make-migrations`) and clear the app's data on test devices.
- After the first release, every schema change bumps `schemaVersion` and ships with a tested migration. Don't use drift's generated migration tests: they break on the `transaction` table name. Rebuild the old version from its exact SQL, open it with the app, and check the data and `validateDatabaseSchema()`.

## Code style

- Keep related code in one file: one file per topic (e.g. all account models, all Drift repositories for setup data), roughly 100–300 lines. Don't create a file per small class; split only when a file grows past ~400 lines.
- Don't write comments that repeat what the code says. Comment only business rules and the reasons behind them.
- Keep the UI simple: no icons on categories or accounts, no user-picked colors.

## Commands

```
flutter pub get
tool/codegen.sh   # Drift codegen (build_runner, then dart format)
flutter analyze                                            # must be clean
flutter test                                               # must be green
flutter test integration_test                              # on emulator/device
```

Every build step ends with `flutter analyze` clean and `flutter test` green before committing.

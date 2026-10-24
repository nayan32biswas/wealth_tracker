# WealthTracker — Build Plan

Personal finance app for Android and iOS: income, expenses, transfers, accounts, net worth, stats. All data stays on the phone in SQLite, with file backup and restore.

The screenshots in `doc/Images/` show which features to include. They are not a design to copy.

## Decisions

| Topic | Decision |
|---|---|
| Stack | Flutter + Drift (type-safe SQLite) |
| Currency | One for the whole app, set in Settings. Decimal places fixed at 2 (changing them would rescale stored amounts) |
| v1 features | Transactions (daily / calendar / monthly views), stats, accounts with net worth, settings |
| Liabilities | An account group can be a liability (card, loan) |
| Design | Our own. Opens on Activity, Material 3, dark theme only (same look for everyone) |
| Add transaction | Full-screen form. Amount and fee use an in-app number pad |
| Extras | Recurring transactions; SQLite and CSV import/export |
| Keep simple | No icons, no user-picked colors, no templates. Lists follow `sort_order` |

Out of scope for v1: budgets, ads, cloud sync, multiple currencies, attachments.

## Schema

- Money is an integer in the smallest unit (paisa). ৳650.00 is stored as `65000`.
- `asset_group.type`: `asset` or `liability`. Drives the Assets / Liabilities / Net worth totals.
- `asset.initial_balance` gives an opening balance without a fake first transaction.
- Category default fee: `fee_type` (none / percent / fixed) + `fee_value`.
- `transaction.fee` is the fee actually charged, stored apart from `amount`. It is pre-filled from the category and editable.
- A transfer is one row: `type = transfer`, `asset_id` = from, `to_asset_id` = to. The fee comes off the source account.
- CHECK rules: transaction `type` ∈ `income` / `expense` / `transfer`; `category.type` ∈ `income` / `expense`.
- `time` (epoch ms) and `date` (`YYYY-MM-DD`). `date` makes day/month grouping fast and free of time-zone bugs. Indexes on `date`, `asset_id`, `category_id`.
- `updated_at` everywhere. Foreign keys on. Groups, accounts, categories and recurring rules use soft delete (`is_deleted`).
- `setting` table (`key`, `value`): currency symbol and code, decimal places, first day of week and month, lock options.
- `recurring_rule` table: `id, note, type, amount, fee, asset_id, to_asset_id, category_id, frequency (daily/weekly/monthly/yearly), interval, start_date, end_date (nullable), next_date, is_active, is_deleted, created_at, updated_at`.
- `transaction.recurring_rule_id` (nullable), unique with `date`, so a rule never creates the same day twice.
- Migrations: until the first public release, schema v1 is edited in place. After that, every change bumps `schemaVersion` with a tested migration (see `AGENTS.md`).

## Seed data

**Starter setup:** added once, on first launch, when the database is empty. All of it can be renamed, reordered or deleted. `sort_order` follows the lists below. All fees start at "none".

| Table | Rows |
|---|---|
| `asset_group` | Cash (asset), Bank (asset), Mobile Wallet (asset), Card (liability), Loan (liability) |
| `asset` | Cash, Bank Account, Mobile Wallet, Credit Card. Opening balance 0 |
| `category` (expense) | Food, Meal, Transport, Utilities, Rent, Shopping, Health, Education, Mobile & Internet, Gift, Bank Charges, Other |
| `category` (income) | Salary, Bonus, Business, Interest, Gift, Other |
| `setting` | ৳ / BDT, 2 decimals, week starts Saturday, month starts day 1, app lock off |

**Demo data:** Settings → Developer → "Load demo data", debug builds only. The developer picks 1–24 months (default 12) and, if there is data already, whether to reset accounts and categories to the starter set first. Entries: opening balances, a card that owes money, monthly salary, recurring rent, daily spending, a default fee and a hand-edited fee, transfers (one with a fee), and notes for search. A pure Dart generator with a fixed seed builds it, so tests use it as fixtures.

## Business rules

- **Balance** = initial + (income − fee) − (expense + fee) − (transfer out + fee) + transfer in. A fee on income (e.g. tax deducted) is taken off what arrives. Liability accounts show the same number as "owed".
- **Fee rounding:** percent fees round half-up to the smallest unit.
- **Recurring:** on app start and resume, create all due transactions up to today, including missed days. Monthly rules on the 29th–31st fall back to the last day of shorter months. Editing a rule changes only future transactions.

## Architecture

Three layers. The UI never talks to the database directly.

```
lib/
  domain/          # pure Dart, no Flutter or Drift imports
    models/        # enums, accounts, categories, transactions, app_settings
    repositories/  # repositories.dart: all interfaces
    services/      # money, reports, calendar, recurring
  data/
    db/            # tables, app_database, seed_data
    repositories/  # drift_repositories, drift_transactions
    io/            # backup (SQLite + CSV)
  presentation/
    app/           # app + router, providers, theme
    widgets/       # common, period_switcher, number_pad
    features/      # transactions/, stats/, accounts/, settings/, security/
  main.dart        # wires dependencies
test/              # mirrors lib/
integration_test/
```

## UI

Material 3, neutral palette, one accent color. Text only. Chart colors come from a fixed palette by rank.

Bottom navigation: **Activity · Stats · Accounts · Settings**. The app opens on Activity.

- **Activity:** period bar with a view menu: Daily (month grouped by day), Calendar (month grid), Monthly (year, one row per month). Income, expense and net sit above the list. Each entry shows account, category with its note in small grey text underneath, and amount. Search by note; a collapsed Filters panel adds a date range, several categories, several accounts, and sort by newest or by amount (largest or smallest money moved).
- **Add / Edit:** full screen. Type, date and time, account (+ to-account for transfers), category, amount, note. Fee and "Repeat" sit behind "More options"; a non-zero fee and the total show under the amount. Save at the bottom, Delete in the top bar.
- **Number pad:** opens for Amount and Fee (0–9, `00`, `.`, backspace, Done). Blocks extra decimals and a second `.`. A reusable widget with its own tested input logic.
- **Period bar** (Activity, Stats): previous / period / next, plus a menu. Tap the period to jump. No week periods. Long text cut with "…", large amounts shrink to fit.
- **Stats:** collapsible sections in one list. One section open at a time. A section loads data only while open.
  - Categories: Income / Expense toggle, ranked list with bar, % and amount. Tap a row for its transactions.
  - Trends: net-worth line, income vs expense bars and a table over 6 months or 6 years (Monthly / Yearly), stepped back one month or year at a time down to the first entry.
- **Accounts:** groups with subtotals, Assets / Liabilities / Net worth header, account detail with its balance and an Activity-style view of that account (Daily or Monthly; In / Out / Net counting transfers, so Net is how much the balance moved).
- **Settings:** categories, groups and accounts (add, rename, drag to reorder, soft delete, default fee); recurring rules; currency and format; week/month start; security; import/export.

## Status

Steps 0–11 are done: setup, data layer, domain logic, app shell, settings, transactions, recurring, accounts, stats, security, import/export, polish.

- **Security:** PIN stored as a salted hash in secure storage, with optional fingerprint / Face ID. The PIN is always the fallback. Locks on cold start and after a set time in the background. Hides content in the recent-apps screen.
- **Import / export:** SQLite export via `VACUUM INTO`. SQLite import is a full restore, only for a file that matches the app's schema exactly (version, tables, columns). An optional password encrypts the backup as a `.wtbackup` file (PBKDF2-SHA256 with 600,000 rounds, then AES-256-GCM; layout in `lib/domain/services/backup_crypto.dart`). Restore spots encrypted files by their `WTBACKUP` header, not the file name. CSV columns: `date, time, type, amount, fee, account, to_account, category, note`. CSV import adds data after a preview, all or nothing.

Still open:

- Device testing on real Android and iOS phones (biometrics, file sharing).
- iOS builds need a Mac.
- Items in [README → Before any public release](../README.md#before-any-public-release).

## Verification

- Every step ends with `flutter analyze` clean, `flutter test` green, and a commit.
- In-memory SQLite tests prove the numbers.
- End-to-end: `flutter test integration_test` on an Android emulator.

# Open a backup on a computer

A password-protected backup (`.wtbackup`) can be turned back into a plain SQLite file, opened or edited in any SQLite tool, then protected again and restored on the phone. Run this in Git Bash or a Linux shell, after `flutter pub get`:

```bash
tool/backup_crypt.sh decrypt wealthtracker-2026-10-01.wtbackup   # -> wealthtracker-2026-10-01.sqlite
tool/backup_crypt.sh encrypt wealthtracker-2026-10-01.sqlite     # -> wealthtracker-2026-10-01.wtbackup
```

The password is asked for on screen. `-o <file>` picks another output name, and `--force` replaces an existing file. The script uses the app's own encryption code, so the files open on any phone with the app. A restore reads columns by name: extra ones are skipped and missing optional ones get defaults. Every table and required column must be there, and every entry must pass the app's rules, so edit rows, not the table layout.

The decrypted `.sqlite` file is not protected. Delete it when you're done.

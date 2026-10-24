#!/usr/bin/env bash
# Encrypts or decrypts a WealthTracker backup on a computer. The work is done by
# the app's own BackupCipher (tool/backup_crypt.dart), so files stay compatible
# with the phone. Needs the Flutter SDK and `flutter pub get` run once.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: tool/backup_crypt.sh decrypt <file.wtbackup> [-o <out.sqlite>] [--force]
       tool/backup_crypt.sh encrypt <file.sqlite> [-o <out.wtbackup>] [--force]

The password is asked for on screen. Without -o the output goes next to the
input with the other extension. --force replaces an existing output file.
EOF
  exit 64
}

[ $# -ge 2 ] || usage
mode=$1 input=$2
shift 2
case $mode in
  decrypt) ext=sqlite ;;
  encrypt) ext=wtbackup ;;
  *) usage ;;
esac

output='' force=''
while [ $# -gt 0 ]; do
  case $1 in
    -o) [ $# -ge 2 ] || usage; output=$2; shift 2 ;;
    --force) force=1; shift ;;
    *) usage ;;
  esac
done
output=${output:-"${input%.*}.$ext"}

[ -f "$input" ] || { echo "No such file: $input" >&2; exit 1; }
if [ -e "$output" ] && [ -z "$force" ]; then
  echo "$output already exists. Use --force to replace it." >&2
  exit 1
fi

read -rsp 'Password: ' password; echo >&2
if [ "$mode" = encrypt ]; then
  # Same rules as the app's export dialog.
  [ ${#password} -ge 8 ] || { echo 'The password must be at least 8 characters.' >&2; exit 1; }
  read -rsp 'Repeat password: ' again; echo >&2
  [ "$password" = "$again" ] || { echo "The passwords don't match." >&2; exit 1; }
fi

# The password goes through a pipe, not an argument, so it never shows up in
# the process list.
echo "${mode^}ing…" >&2
printf '%s' "$password" | dart "$(dirname "$0")/backup_crypt.dart" "$mode" "$input" "$output"
echo "Wrote $output" >&2

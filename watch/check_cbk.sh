#!/usr/bin/env bash
# Checks CBK's Government Finance Statistics page for a new version of a file.
#
#   watch/check_cbk.sh <name> <link-pattern>
#   e.g. watch/check_cbk.sh public_debt 'Public%20Debt\.csv'
#
# CBK re-uploads files under a new numeric prefix (42346012_Public Debt.csv ->
# 1071243323_Public Debt.csv), so the link is found on the page each time and
# compared, together with a SHA-256 of the file, against watch/<name>.state.
# Prints changed=true|false (and the URL) to $GITHUB_OUTPUT when run in Actions.
set -euo pipefail

NAME="$1"; PATTERN="$2"
PAGE="${CBK_PAGE:-https://www.centralbank.go.ke/statistics/government-finance-statistics/}"
UA="Mozilla/5.0 (compatible; KenyaDebtCounterBot/1.0; +https://kenyadebtcounter.vercel.app)"
DIR="$(cd "$(dirname "$0")" && pwd)"
STATE="$DIR/$NAME.state"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

html="$(curl -fsSL --retry 3 --max-time 60 -A "$UA" "$PAGE")"
path="$(printf '%s' "$html" | grep -oE "href=\"[^\"]*/[0-9]+_${PATTERN}\"" | head -1 | sed -E 's/^href="|"$//g' || true)"
if [ -z "$path" ]; then
  echo "::error::No link matching '${PATTERN}' found on $PAGE (page layout may have changed)"
  exit 1
fi
case "$path" in http*) url="$path" ;; *) url="https://www.centralbank.go.ke${path}" ;; esac

tmp="$(mktemp)"
curl -fsSL --retry 3 --max-time 120 -A "$UA" -o "$tmp" "$url"
sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
lines="$(wc -l < "$tmp" | tr -d ' ')"
last_row="$(grep -E '^[0-9]{4},' "$tmp" | tail -1 | cut -d, -f1,2 || true)"
rm -f "$tmp"

new_state="url=$url
sha256=$sha"
old_state="$(cat "$STATE" 2>/dev/null || true)"

echo "File      : $url"
echo "Rows      : $lines (latest year,month: $last_row)"
if [ "$new_state" = "$old_state" ]; then
  echo "Status    : unchanged since last check"
  { echo "changed=false"; echo "url=$url"; } >> "$OUT"
else
  echo "Status    : NEW VERSION (previous: $(grep '^url=' "$STATE" 2>/dev/null | cut -d= -f2- || echo none))"
  printf '%s\n' "$new_state" > "$STATE.new"
  { echo "changed=true"; echo "url=$url"; echo "latest=$last_row"; } >> "$OUT"
fi

#!/usr/bin/env bash
# Checks CBK's site for new Weekly Bulletin PDFs (/uploads/weekly_bulletin/...).
#
#   watch/check_bulletin.sh
#
# Every bulletin link already seen is kept in watch/weekly_bulletin.seen; any
# link not in it is new. The first run only records what is there (no alert).
# Pages checked: $BULLETIN_PAGES (space-separated), by default CBK's Weekly
# Bulletin listings and home page. Prints changed=true|false and the new links
# to $GITHUB_OUTPUT when run in Actions; writes watch/weekly_bulletin.seen.new
# for the workflow to commit once the alert has been sent.
set -euo pipefail

PAGES="${BULLETIN_PAGES:-https://www.centralbank.go.ke/releases/weekly-bulletin/ https://www.centralbank.go.ke/reports/weekly-bulletin/ https://www.centralbank.go.ke/}"
UA="Mozilla/5.0 (compatible; KenyaDebtCounterBot/1.0; +https://kenyadebtcounter.vercel.app)"
BASE="${CBK_BASE:-https://www.centralbank.go.ke}"
DIR="$(cd "$(dirname "$0")" && pwd)"
SEEN="$DIR/weekly_bulletin.seen"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

links=""
for page in $PAGES; do
  html="$(curl -fsSL --retry 3 --max-time 60 -A "$UA" "$page" || true)"
  found="$(printf '%s' "$html" | grep -oiE "href=[\"'][^\"']*/uploads/weekly_bulletin/[^\"']+\.pdf[\"']" \
           | sed -E "s/^href=[\"']|[\"']$//g" || true)"
  [ -n "$found" ] && links="$links"$'\n'"$found"
done
links="$(printf '%s\n' "$links" | sed '/^$/d' | sed -E "s#^/#$BASE/#; s/ /%20/g" | sort -u)"

if [ -z "$links" ]; then
  echo "::error::No weekly bulletin links found on: $PAGES (page layout may have changed)"
  exit 1
fi
count="$(printf '%s\n' "$links" | wc -l | tr -d ' ')"
echo "Bulletin links found: $count"

if [ ! -f "$SEEN" ]; then
  printf '%s\n' "$links" > "$SEEN.new"
  echo "First run: recorded $count bulletins; no alert."
  { echo "changed=false"; echo "first_run=true"; } >> "$OUT"
  exit 0
fi

new="$(comm -13 <(sort -u "$SEEN") <(printf '%s\n' "$links") || true)"
if [ -z "$new" ]; then
  echo "No new bulletin."
  echo "changed=false" >> "$OUT"
else
  echo "NEW bulletin(s):"; printf '%s\n' "$new"
  sort -u "$SEEN" <(printf '%s\n' "$links") > "$SEEN.new"
  { echo "changed=true"; echo "links<<EOF_LINKS"; printf '%s\n' "$new"; echo "EOF_LINKS"; } >> "$OUT"
fi

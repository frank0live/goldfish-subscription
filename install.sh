#!/usr/bin/env bash
# Install / update Goldfish Subscription sub-page for 3x-ui panels.
#   bash <(curl -fsSL https://raw.githubusercontent.com/frank0live/goldfish-subscription/main/install.sh)
#
# What it does:
#   1. Sanity: root + 3x-ui panel detected (fails early on the wrong server)
#   2. Download sub.html from the repo, compute sha256
#   3. Install into a theme dir
#   4. Back up x-ui.db (WAL-safe .backup), set the `subThemeDir` settings key
#      (single-key upsert — UPDATE alone silently no-ops on a missing key)
#   5. Restart panel; health-check; auto-revert on failure
#

# Env knobs:
#   GOLDFISH_THEME_DIR=/etc/3x-ui/sub_templates/goldfish   install folder
#   GOLDFISH_BASE=https://…/main                          custom file source (testing)
set -u

REPO="frank0live/goldfish-subscription"
BRANCH="main"
BASE="${GOLDFISH_BASE:-https://raw.githubusercontent.com/$REPO/$BRANCH}"
INSTALLER_VERSION="1.0.0"
THEME_DIR="${GOLDFISH_THEME_DIR:-/etc/3x-ui/sub_templates/goldfish}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*"; exit 1; }

say "==== Goldfish Subscription installer v$INSTALLER_VERSION ===="

# 0) helpers ---------------------------------------------------------------
# sqlite3 is optional: python3 is bundled with 3x-ui docker images, sqlite3 is not.
# Prefer sqlite3 when present, else a tiny python shim with the same CLI shape.
have_sqlite3=0
command -v sqlite3 >/dev/null 2>&1 && have_sqlite3=1

db_query() {  # db_query <sql>  -> rows on stdout
  if [ "$have_sqlite3" = 1 ]; then
    sqlite3 "$DB" "$1"
  else
    DB="$DB" SQL="$1" python3 - <<'PYEOF'
import os, sqlite3
con = sqlite3.connect(os.environ["DB"])
for row in con.execute(os.environ["SQL"]):
    print("|".join("" if v is None else str(v) for v in row))
PYEOF
  fi
}

find_sub_id() {  # find_sub_id <db> [count] -> first subId (or unique count)
  DB="$1" MODE="${2:-first}" python3 - <<'PYEOF'
import json, os, sqlite3
db, mode = os.environ["DB"], os.environ["MODE"]
found = set()
try:
    con = sqlite3.connect(db)
except Exception:
    con = None
if con is not None:
    # modern 3.8.x schema keeps subIds in the normalized `clients` table
    try:
        for (sid,) in con.execute("SELECT DISTINCT sub_id FROM clients WHERE sub_id IS NOT NULL AND sub_id != ''"):
            sid = str(sid).strip()
            if sid:
                found.add(sid)
    except Exception:
        pass
    # older panels keep the client JSON inside inbounds.settings
    try:
        for (raw,) in con.execute("SELECT settings FROM inbounds WHERE settings IS NOT NULL"):
            try:
                s = json.loads(raw)
            except Exception:
                continue
            for c in (s.get("clients") or []):
                sid = str(c.get("subId") or c.get("sub_id") or "").strip()
                if sid:
                    found.add(sid)
    except Exception:
        pass
if mode == "count":
    print(len(found))
elif found:
    print(sorted(found)[0])
PYEOF
}

db_backup() {  # db_backup <dest>
  if [ "$have_sqlite3" = 1 ]; then
    sqlite3 "$DB" ".backup $1" 2>/dev/null || true
  else
    DB="$DB" DEST="$1" python3 - <<'PYEOF'
import os, sqlite3
src = sqlite3.connect(os.environ["DB"]); dst = sqlite3.connect(os.environ["DEST"])
with dst:
    src.backup(dst)
dst.close(); src.close()
PYEOF
  fi
}

# 1) preflight ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root"

DB="/etc/x-ui/x-ui.db"
[ -f "$DB" ] || die "3x-ui database not found at $DB — is 3x-ui installed on this server?"

panel_version=""
# `x-ui` is a shell menu wrapper in docker images and prints the menu, not the
# version. Probe real binaries; accept only output that is a bare x.y.z line.
for cand in /app/x-ui /usr/local/x-ui/bin/version /usr/local/x-ui/x-ui /usr/bin/x-ui; do
  [ -x "$cand" ] || continue
  head -c2 "$cand" 2>/dev/null | grep -q '#!' && continue   # skip shell wrappers
  v="$("$cand" -v 2>/dev/null | head -1 | tr -d ' \r\n' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  [ -n "$v" ] && { panel_version="$v"; break; }
done
[ -n "$panel_version" ] || panel_version="unknown"
say "[1/5] panel detected (3x-ui $panel_version)"

# 2) download ----------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say "[2/5] downloading sub.html ..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --max-time 60 "$BASE/sub.html" -o "$TMP/sub.html" || die "download failed ($BASE/sub.html)"
else
  wget -qO "$TMP/sub.html" "$BASE/sub.html" || die "download failed ($BASE/sub.html)"
fi
[ -s "$TMP/sub.html" ] || die "downloaded file is empty"
subhtml_sha256="$(sha256sum "$TMP/sub.html" | awk '{print $1}')"
subhtml_bytes="$(wc -c < "$TMP/sub.html")"
say "      ${subhtml_bytes} bytes, sha256 ${subhtml_sha256:0:16}…"

# 3) install theme file ------------------------------------------------------
say "[3/5] installing theme into $THEME_DIR ..."
mkdir -p "$THEME_DIR"; chmod 755 "$THEME_DIR"
cp "$TMP/sub.html" "$THEME_DIR/sub.html"; chmod 644 "$THEME_DIR/sub.html"
say "      $THEME_DIR/sub.html"

# 4) DB backup + single-key upsert -------------------------------------------
say "[4/5] panel DB: backup + set subThemeDir ..."
db_backup "/root/x-ui.db.bak-goldfish-$(date +%Y%m%d-%H%M%S)"
prev_value="$(db_query "SELECT value FROM settings WHERE key='subThemeDir'" 2>/dev/null | head -1)"
THEME_DIR="$THEME_DIR" DB="$DB" python3 - <<'PYEOF' || die "DB upsert failed"
import os, sqlite3
d = os.environ["THEME_DIR"].rstrip("/") + "/"
con = sqlite3.connect(os.environ["DB"])
row = con.execute("SELECT value FROM settings WHERE key='subThemeDir'").fetchone()
if row:
    con.execute("UPDATE settings SET value=? WHERE key='subThemeDir'", (d,)); print("      subThemeDir updated ->", d)
else:
    con.execute("INSERT INTO settings (key, value) VALUES ('subThemeDir', ?)", (d,)); print("      subThemeDir inserted ->", d)
con.commit()
PYEOF

# 5) restart + health check (auto-revert on failure) --------------------------
say "[5/5] restarting panel + health check ..."
if command -v x-ui >/dev/null 2>&1; then
  x-ui restart >/dev/null 2>&1 || true
fi
sleep 3

health=0
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet x-ui 2>/dev/null; then
    health=1; say "      panel service is active (systemd)"
  fi
else
  say "      no systemd (docker?) — relying on port check"
fi
panel_port="$(db_query "SELECT value FROM settings WHERE key='webPort'" 2>/dev/null | head -1)"
[ -n "$panel_port" ] || panel_port=2053
http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:$panel_port/" 2>/dev/null || echo 000)"
if [ "$http_code" != "000" ] && [ "$http_code" != "000000" ]; then
  health=1; say "      panel HTTP port responds ($http_code)"
fi

if [ "$health" = 0 ]; then
  say "      panel did NOT come back — reverting subThemeDir"
  PREV_VALUE="$prev_value" DB="$DB" python3 - <<'PYEOF'
import os, sqlite3
prev = os.environ.get("PREV_VALUE", "")
con = sqlite3.connect(os.environ["DB"])
if prev:
    con.execute("UPDATE settings SET value=? WHERE key='subThemeDir'", (prev,))
else:
    con.execute("DELETE FROM settings WHERE key='subThemeDir'")
con.commit()
PYEOF
  command -v x-ui >/dev/null 2>&1 && { x-ui restart >/dev/null 2>&1 || true; }
  die "panel failed to start; subThemeDir reverted to previous value"
fi

# find one real sub link and confirm the page renders in HTML mode. Both the sub
# path and the sub port are configurable in the panel — probe the likely combos.
suburl=""
sub_id="$(find_sub_id "$DB" 2>/dev/null || true)"
iid="$(db_query "SELECT id FROM inbounds LIMIT 1" 2>/dev/null | head -1)"
sub_path="$(db_query "SELECT value FROM settings WHERE key='subPath'" 2>/dev/null | head -1)"
[ -n "$sub_path" ] || sub_path="/sub/"
case "$sub_path" in /*) ;; *) sub_path="/$sub_path" ;; esac
case "$sub_path" in */) ;; *) sub_path="$sub_path/" ;; esac
sub_port="$(db_query "SELECT value FROM settings WHERE key='subPort'" 2>/dev/null | head -1)"
[ -n "$sub_port" ] || sub_port=2096
web_port2="$(db_query "SELECT value FROM settings WHERE key='webPort'" 2>/dev/null | head -1)"
[ -n "$web_port2" ] || web_port2="$panel_port"
key_part="${sub_id:-$iid}"
if [ -n "$key_part" ]; then
  for u in "http://127.0.0.1:$sub_port$sub_path$key_part" "http://127.0.0.1:$web_port2$sub_path$key_part" "http://127.0.0.1:$web_port2/sub/$key_part"; do
    body="$(curl -s -H 'Accept: text/html' -A 'Mozilla/5.0' --max-time 20 "$u" 2>/dev/null || true)"
    if printf '%s' "$body" | grep -q 'cfgSource'; then
      say "      rendered sub page OK ($(printf '%s' "$body" | wc -c) bytes) — $u"
      suburl="$u"; break
    fi
  done
  [ -n "$suburl" ] || say "      WARN: could not confirm rendered theme — check the panel subscription URL manually"
fi

say ""
say "======================================================"
say " Goldfish Subscription installed successfully"
say "   theme dir : $THEME_DIR"
say "   file      : $THEME_DIR/sub.html ($subhtml_bytes bytes)"
say "   sha256    : $subhtml_sha256"
say "   panel     : 3x-ui $panel_version"
say "   sub page  : ${suburl:-open one of your subscription links}"
say "------------------------------------------------------"
say " Update    : re-run the same install command"
say " Support   : https://t.me/master_supports"
say "======================================================"

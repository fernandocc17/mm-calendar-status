#!/usr/bin/env bash
#
# install.sh - interactive installer for mm-calendar-status
#
# Automates everything in the README: dependency install, EDS calendar
# selection, Mattermost token + user_id setup, config generation, and the
# systemd user timer. Safe to re-run; it detects what is already configured
# and only fixes what is missing.
#
# Usage:  ./install.sh
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Constants and helpers
# --------------------------------------------------------------------------- #

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/mm-calendar-status"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
CONFIG_FILE="${CONFIG_DIR}/config.ini"
TOKEN_FILE="${CONFIG_DIR}/mm_token"
SCRIPT_DEST="${BIN_DIR}/mm_status.py"

# System python is required: the GObject bindings install against /usr/bin/python3,
# not against pyenv/conda interpreters.
PY="/usr/bin/python3"

DEFAULT_SERVER="https://chat.canonical.com"
DEFAULT_DOMAIN="canonical.com"

APT_PACKAGES=(python3-gi gir1.2-edataserver-1.2 gir1.2-ecal-2.0)

# Colors (fall back to empty if not a tty)
if [[ -t 1 ]]; then
    BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi

info()  { echo -e "${BOLD}==>${RESET} $*"; }
ok()    { echo -e "${GREEN}OK${RESET}  $*"; }
warn()  { echo -e "${YELLOW}!!${RESET}  $*"; }
err()   { echo -e "${RED}ERR${RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

ask() {
    # ask "prompt" "default" -> echoes the answer
    local prompt="$1" default="${2:-}" reply
    if [[ -n "$default" ]]; then
        read -r -p "$(echo -e "${prompt} [${default}]: ")" reply
        echo "${reply:-$default}"
    else
        read -r -p "$(echo -e "${prompt}: ")" reply
        echo "$reply"
    fi
}

confirm() {
    # confirm "question" -> returns 0 for yes
    local reply
    read -r -p "$(echo -e "$1 [y/N]: ")" reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# --------------------------------------------------------------------------- #
# Step 0: sanity
# --------------------------------------------------------------------------- #

[[ -f "${SCRIPT_DIR}/mm_status.py" ]] || die "mm_status.py not found next to install.sh"
[[ -x "$PY" ]] || die "System python not found at ${PY}"

info "mm-calendar-status installer"
echo

# --------------------------------------------------------------------------- #
# Step 1: Python dependencies
# --------------------------------------------------------------------------- #

info "Checking Python GObject dependencies"

check_imports() {
    "$PY" - <<'PYEOF' 2>/dev/null
import gi
gi.require_version("EDataServer", "1.2")
gi.require_version("ECal", "2.0")
from gi.repository import EDataServer, ECal  # noqa
PYEOF
}

if check_imports; then
    ok "EDS/ECal bindings already present"
else
    warn "Missing GObject bindings (python3-gi, gir1.2-edataserver-1.2, gir1.2-ecal-2.0)"
    if confirm "Install them now with apt? (requires sudo)"; then
        sudo apt update
        sudo apt install -y "${APT_PACKAGES[@]}"
        check_imports || die "Bindings still not importable after install"
        ok "Dependencies installed"
    else
        die "Cannot continue without the GObject bindings"
    fi
fi
echo

# --------------------------------------------------------------------------- #
# Step 2: GNOME Online Accounts / EDS calendar
# --------------------------------------------------------------------------- #

info "Looking for calendars in Evolution Data Server"

# Dump all EDS sources to a temp file once.
EDS_DUMP="$(mktemp)"
trap 'rm -f "$EDS_DUMP"' EXIT

if ! gdbus call --session \
        --dest org.gnome.evolution.dataserver.Sources5 \
        --object-path /org/gnome/evolution/dataserver/SourceManager \
        --method org.freedesktop.DBus.ObjectManager.GetManagedObjects \
        > "$EDS_DUMP" 2>/dev/null; then
    err "Could not query Evolution Data Server."
    err "Make sure your Google account is added in Settings > Online Accounts"
    err "with Calendar enabled, then open the GNOME Calendar app once."
    die "EDS not reachable"
fi

# Parse UID + DisplayName pairs. gdbus emits literal \n separators.
mapfile -t CAL_LINES < <("$PY" - "$EDS_DUMP" "$DEFAULT_DOMAIN" <<'PYEOF'
import sys, re
data = open(sys.argv[1]).read()
domain = sys.argv[2]
pairs = re.findall(r"UID': <'([^']+)'>.*?DisplayName=(.+?)\\n", data)
# Prefer entries that look like calendars tied to an email address; show all but
# sort so that domain matches and address-like names come first.
def score(name):
    s = 0
    if "@" in name: s -= 2
    if domain and domain in name: s -= 1
    return s
pairs.sort(key=lambda p: score(p[1]))
for uid, name in pairs:
    print(f"{uid}\t{name}")
PYEOF
)

[[ ${#CAL_LINES[@]} -gt 0 ]] || die "No calendars found in EDS. Connect Google Calendar in GNOME first."

echo "Found these calendar sources:"
echo
i=1
declare -a UIDS NAMES
for line in "${CAL_LINES[@]}"; do
    uid="${line%%$'\t'*}"
    name="${line#*$'\t'}"
    UIDS[i]="$uid"
    NAMES[i]="$name"
    printf "  %2d) %s\n" "$i" "$name"
    ((i++))
done
echo
info "Pick your PRIMARY calendar (its name is usually your email address)."
sel="$(ask "Calendar number" "1")"
[[ "$sel" =~ ^[0-9]+$ ]] && [[ -n "${UIDS[sel]:-}" ]] || die "Invalid selection"

CAL_UID="${UIDS[sel]}"
CAL_NAME="${NAMES[sel]}"
ok "Selected: ${CAL_NAME}"

# Derive email: if the name is an address use it, else ask.
if [[ "$CAL_NAME" == *@* ]]; then
    CAL_EMAIL="$CAL_NAME"
else
    CAL_EMAIL="$(ask "Your calendar account email")"
fi
echo

# --------------------------------------------------------------------------- #
# Step 3: timezone
# --------------------------------------------------------------------------- #

info "Detecting timezone"
DETECTED_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)"
CAL_TZ="$(ask "IANA timezone" "$DETECTED_TZ")"
ok "Timezone: ${CAL_TZ}"
echo

# --------------------------------------------------------------------------- #
# Step 4: Mattermost server + token + user_id
# --------------------------------------------------------------------------- #

info "Mattermost setup"
MM_SERVER="$(ask "Mattermost server URL" "$DEFAULT_SERVER")"
MM_SERVER="${MM_SERVER%/}"

echo
echo "Create a Personal Access Token in Mattermost (web UI):"
echo "  avatar > Profile > Security > Personal Access Tokens > Create Token"
echo "Copy the Access Token value (not the Token ID)."
echo

# Reuse an existing token file if present and valid.
MM_TOKEN=""
if [[ -f "$TOKEN_FILE" ]]; then
    if confirm "A token file already exists. Reuse it?"; then
        MM_TOKEN="$(cat "$TOKEN_FILE")"
    fi
fi

verify_token() {
    # verify_token <server> <token> -> prints user_id on success
    "$PY" - "$1" "$2" <<'PYEOF'
import sys, json, urllib.request, urllib.error
server, token = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"{server}/api/v4/users/me",
    headers={"Authorization": f"Bearer {token}"},
)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        data = json.loads(r.read())
        uid = data.get("id", "")
        user = data.get("username", "")
        if uid and not uid.startswith("api."):
            print(f"{uid}\t{user}")
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
PYEOF
}

MM_USER_ID=""
while true; do
    if [[ -z "$MM_TOKEN" ]]; then
        read -r -s -p "Paste your Mattermost token: " MM_TOKEN
        echo
    fi
    info "Verifying token against ${MM_SERVER}"
    if result="$(verify_token "$MM_SERVER" "$MM_TOKEN")"; then
        MM_USER_ID="${result%%$'\t'*}"
        mm_user="${result#*$'\t'}"
        ok "Token valid. Logged in as ${mm_user} (id ${MM_USER_ID})"
        break
    else
        err "Token verification failed."
        MM_TOKEN=""
        confirm "Try a different token?" || die "Cannot continue without a valid token"
    fi
done
echo

# --------------------------------------------------------------------------- #
# Step 5: write files
# --------------------------------------------------------------------------- #

info "Writing configuration"
mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$SYSTEMD_DIR"

install -m 755 "${SCRIPT_DIR}/mm_status.py" "$SCRIPT_DEST"
ok "Installed script to ${SCRIPT_DEST}"

printf '%s' "$MM_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
ok "Saved token to ${TOKEN_FILE} (mode 600)"

# Pull emoji/keyword defaults straight from config.ini.example so the installer
# does not duplicate them. We only override the discovered values.
if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
    warn "Existing config backed up"
fi

cat > "$CONFIG_FILE" <<EOF
[calendar]
uid = ${CAL_UID}
email = ${CAL_EMAIL}
timezone = ${CAL_TZ}
eds_connect_timeout = 60
lookahead_minutes = 2

[mattermost]
server = ${MM_SERVER}
user_id = ${MM_USER_ID}
token_file = ${TOKEN_FILE}
http_timeout = 10

[behavior]
pause_file = /tmp/mm_status_pause
log_file = ${CONFIG_DIR}/mm_status.log

[keywords]
ooo = out of office,ooo,ask before booking,exercise,break,lunch
focus = focus

[status]
ooo_emoji = shufflepartyparrot
ooo_text = Out of office
focus_emoji = dart
focus_text = Focus time
meeting_emoji = meet
EOF
chmod 600 "$CONFIG_FILE"
ok "Wrote ${CONFIG_FILE}"
echo

# --------------------------------------------------------------------------- #
# Step 6: smoke test
# --------------------------------------------------------------------------- #

info "Running the script once (first EDS connect can take ~40s)"
if "$PY" "$SCRIPT_DEST"; then
    ok "Script ran successfully"
    tail -n 1 "${CONFIG_DIR}/mm_status.log" 2>/dev/null || true
else
    die "Script failed. Check ${CONFIG_DIR}/mm_status.log"
fi
echo

# --------------------------------------------------------------------------- #
# Step 7: systemd timer
# --------------------------------------------------------------------------- #

info "Installing systemd user units"
# Rewrite ExecStart to the detected system python so the gi bindings resolve
# regardless of pyenv/conda on PATH.
sed "s|^ExecStart=.*|ExecStart=${PY} %h/.local/bin/mm_status.py|" \
    "${SCRIPT_DIR}/systemd/mm-calendar-status.service" > "${SYSTEMD_DIR}/mm-calendar-status.service"
cp "${SCRIPT_DIR}/systemd/mm-calendar-status.timer"   "${SYSTEMD_DIR}/"
systemctl --user daemon-reload
systemctl --user enable --now mm-calendar-status.timer
ok "Timer enabled"
echo

# Re-arm so list-timers shows a clean NEXT (avoids the cosmetic n/a right after
# enable --now while the first service run is still warming up EDS).
systemctl --user restart mm-calendar-status.timer
sleep 1
systemctl --user show mm-calendar-status.timer \
    -p NextElapseUSecRealtime -p Result | sed 's/^/    /'
echo

info "Done."
echo "Control commands:"
echo "  touch /tmp/mm_status_pause        # pause (status left untouched)"
echo "  rm /tmp/mm_status_pause           # resume"
echo "  systemctl --user stop  mm-calendar-status.timer"
echo "  systemctl --user start mm-calendar-status.timer"
echo "  ${PY} ${SCRIPT_DEST}   # run once"
echo "  tail -f ${CONFIG_DIR}/mm_status.log"

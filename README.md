# mm-calendar-status

Automatically sets your Mattermost custom status from your Google Calendar.

When you are in a meeting, on focus time, or out of office, this reflects it in
Mattermost without you touching anything. The status auto-expires at the end of
the event.

It reads the calendar **locally** through GNOME's Evolution Data Server (EDS),
the same backend GNOME Calendar uses, so there is **no OAuth app, no Google
Cloud project, and no API key**. If your Google account is already connected in
GNOME Online Accounts, the calendar data is already on your machine and this
just reads it.

## How it works

1. A systemd user timer runs the script every 5 minutes.
2. The script asks EDS for events on your calendar and finds the one active now
   (or starting within the next couple of minutes).
3. It classifies that event and sets the matching Mattermost custom status,
   with `expires_at` set to the event's end time.
4. With no active event, it clears the status.

### Status mapping

| Event                                          | Emoji                | Status text   |
| ---------------------------------------------- | -------------------- | ------------- |
| Title matches an OOO keyword                   | `:shufflepartyparrot:` | Out of office |
| Title matches a focus keyword                  | `:dart:`             | Focus time    |
| Anything else (a real meeting)                 | `:meet:`             | Event title   |

Default OOO keywords: `out of office`, `ooo`, `ask before booking`, `exercise`,
`break`, `lunch`. Default focus keyword: `focus`. All are configurable and
matched case-insensitively as substrings of the event title.

Events you have **declined** (your `PARTSTAT` is `DECLINED`) are ignored.

### Conflict resolution

When several events overlap, one wins, in this order:

1. **Type**: OOO beats meeting beats focus.
2. **Google Meet**: among equals, an event with a Meet link beats one without.
3. **Soonest end**: among equals, the event ending first wins, so the status
   rolls over to the next one as soon as possible.

## Requirements

- Ubuntu 24.04+ (or any distro with GNOME / Evolution Data Server and systemd).
- A Google account connected in **GNOME Online Accounts** with Calendar enabled.
- A Mattermost account that allows **Personal Access Tokens** (or admin help to
  enable them).
- Python 3.11+ (for `zoneinfo` and `X | None` typing).

The emoji you reference (`meet`, `shufflepartyparrot`, etc.) must already exist
on your Mattermost server. Swap them in `config.ini` for whatever your instance
has.

## Install

### Quick install (recommended)

First connect your Google account in **Settings > Online Accounts** with
**Calendar** enabled, and open the GNOME **Calendar** app once so events sync
locally. Then run the installer:

```bash
./install.sh
```

It is interactive and idempotent (safe to re-run). It will:

- check the Python GObject bindings and offer to `apt install` them if missing,
- list your EDS calendars and let you pick yours from a numbered menu (your
  primary calendar, named after your email, is sorted to the top),
- detect your timezone,
- prompt for your Mattermost token, verify it, and pull your `user_id`
  automatically,
- write `config.ini` and the token file with correct permissions,
- run a smoke test, then install and start the systemd user timer.

The only thing it cannot do for you is connect the Google account in GNOME
(that is a graphical OAuth flow); do that first.

If you prefer to understand or do each step by hand, the manual instructions
below produce the same result.

### Manual install

### Step 1 — Connect Google Calendar in GNOME

Open **Settings > Online Accounts**, add (or select) your Google account, and
make sure **Calendar** is toggled on. Open the GNOME **Calendar** app once and
confirm your events show up. EDS now syncs the calendar locally; everything
below reads from that local copy.

If you have multiple calendars (shared team calendars, holidays, etc.), you can
uncheck the ones you do not care about in GNOME Calendar's sidebar. This script
only reads the single calendar UID you configure, so extra calendars do not
affect it.

### Step 2 — Find your calendar's EDS UID

List all EDS sources and pick the one whose `DisplayName` is your email address
(that is your primary calendar):

```bash
gdbus call --session \
  --dest org.gnome.evolution.dataserver.Sources5 \
  --object-path /org/gnome/evolution/dataserver/SourceManager \
  --method org.freedesktop.DBus.ObjectManager.GetManagedObjects \
  > /tmp/eds_sources.txt

python3 << 'PYEOF'
import re
data = open("/tmp/eds_sources.txt").read()
# gdbus emits each source's config on one logical line with literal "\n"
# separators, so we match UID then the DisplayName that follows it.
for uid, name in re.findall(r"UID': <'([^']+)'>.*?DisplayName=(.+?)\\n", data):
    print(f"{uid}  {name}")
PYEOF
```

(`gdbus` emits the source config with literal `\n` separators rather than real
newlines, which is why the pattern matches on `\n`.)

The line whose name equals your account email (e.g. `you@example.com`) is your
primary calendar. Copy that UID; it goes into `config.ini` as `calendar.uid`.

> Note: the D-Bus interface name (`Sources5`) can vary slightly by EDS version.
> If the call errors, introspect what is available:
> ```bash
> gdbus introspect --session --dest org.gnome.evolution.dataserver.Sources5 \
>   --object-path /org/gnome/evolution/dataserver/SourceManager | head -n 40
> ```

### Step 3 — Mattermost Personal Access Token

In Mattermost (the **web** UI, not the desktop app): click your avatar >
**Profile** > **Security** > **Personal Access Tokens** > **Create Token**.
Name it something like `calendar-status`. Copy the **Access Token** value (not
the Token ID) immediately; it is shown only once.

If you do not see that section, your admin has disabled personal access tokens
and you will need them to enable it.

Verify the token works and grab your **user id** at the same time:

```bash
curl -s \
  -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  https://chat.example.com/api/v4/users/me \
  | python3 -m json.tool | grep -E '"id"|"username"'
```

You should get back your `id` and `username`. The `id` value is your
`mattermost.user_id`.

### Step 4 — Install the files

```bash
# the script
mkdir -p ~/.local/bin
install -m 755 mm_status.py ~/.local/bin/mm_status.py

# config dir
mkdir -p ~/.config/mm-calendar-status
cp config.ini.example ~/.config/mm-calendar-status/config.ini
```

Save the token to its own file with tight permissions (note `-n`, no trailing
newline):

```bash
echo -n "YOUR_TOKEN_HERE" > ~/.config/mm-calendar-status/mm_token
chmod 600 ~/.config/mm-calendar-status/mm_token
```

Edit `~/.config/mm-calendar-status/config.ini` and fill in at least:

- `[calendar] uid` — from Step 2
- `[calendar] email` — your account email
- `[calendar] timezone` — your IANA timezone, e.g. `America/Mexico_City`
- `[mattermost] server` — your server base URL
- `[mattermost] user_id` — from Step 3

### Step 5 — Dependencies

```bash
sudo apt install python3-gi gir1.2-edataserver-1.2 gir1.2-ecal-2.0
```

> The GObject bindings install against the **system** Python
> (`/usr/bin/python3`). If you use pyenv/conda, run the script with the system
> interpreter (the service unit already hardcodes the script path, which uses
> the `#!/usr/bin/env python3` shebang; if your default `python3` is not the
> system one, change the unit's `ExecStart` to
> `/usr/bin/python3 %h/.local/bin/mm_status.py`).

### Step 6 — Run it once by hand

```bash
/usr/bin/python3 ~/.local/bin/mm_status.py
cat ~/.config/mm-calendar-status/mm_status.log
```

The **first** EDS connection after login can take ~40 seconds while the backend
warms up; later runs are fast. The log should show a `Status set` or
`Status cleared` line. Check Mattermost to confirm the status appears.

### Step 7 — Install the systemd timer

```bash
mkdir -p ~/.config/systemd/user
cp systemd/mm-calendar-status.service ~/.config/systemd/user/
cp systemd/mm-calendar-status.timer   ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable --now mm-calendar-status.timer
systemctl --user list-timers mm-calendar-status.timer
```

The timer fires every 5 minutes on the wall clock (`:00`, `:05`, ...). The
script's `lookahead_minutes` (default 2) makes the status flip just before
meetings that start on the `:00/:15/:30/:45` marks.

## Usage

```bash
# Pause without stopping the timer (status is left untouched while paused)
touch /tmp/mm_status_pause
# Resume
rm /tmp/mm_status_pause

# Stop / start the timer entirely
systemctl --user stop  mm-calendar-status.timer
systemctl --user start mm-calendar-status.timer

# Run once, right now
/usr/bin/python3 ~/.local/bin/mm_status.py

# Logs
tail -f ~/.config/mm-calendar-status/mm_status.log     # script's own log
journalctl --user -u mm-calendar-status.service -f     # systemd's view
```

## Configuration reference

All settings live in `config.ini`; see `config.ini.example` for the full list
with comments. Highlights:

- `[keywords] ooo` / `focus` — comma-separated, case-insensitive title matches.
- `[status] *_emoji` / `*_text` — customize emoji and text per event type.
  Emoji are Mattermost shortcodes **without** colons and must exist on your
  server.
- `[calendar] lookahead_minutes` — how early to flip the status before an event
  starts.

You can point the script at a different config directory with the
`MM_STATUS_CONFIG_DIR` environment variable.

## Troubleshooting

**First run hangs for ~40s.** Expected. EDS warms up the backend on the first
`connect_sync` after login. Subsequent runs are quick. If it consistently times
out, raise `[calendar] eds_connect_timeout`.

**No events ever match.** Confirm the UID in `config.ini` is your **primary**
calendar (DisplayName == your email), not a shared/holiday calendar. Re-run
Step 2. Also verify GNOME Calendar itself shows the events.

**Status not changing / 401 errors in the log.** Your token is wrong or expired.
Personal Access Tokens do not expire on their own, but they can be revoked by an
admin. Re-create it (Step 3) and rewrite `mm_token`. Test with the `curl` from
Step 3.

**Wrong meeting wins when events overlap.** Review the conflict-resolution
rules above and tune `[keywords]` so events are classified the way you expect.

**Declined meetings still show.** The script matches your `PARTSTAT` by the
`email` in `config.ini`. Make sure it is exactly the address listed as an
attendee on your events.

**Times look off by hours.** Set `[calendar] timezone` to your real IANA zone.
Events carrying a `TZID` are honored as-is; the configured timezone is the
fallback and defines what "today" means.

## License

MIT. See [LICENSE](LICENSE).

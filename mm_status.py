#!/usr/bin/env python3
"""
Mattermost status sync from Google Calendar via EDS (GNOME Evolution Data Server).

Reads the currently active event from the user's Google Calendar (synced locally
through GNOME Online Accounts / Evolution Data Server) and reflects it as a
Mattermost custom status. Intended to run every few minutes via a systemd user
timer.

Pause without stopping the timer:  touch /tmp/mm_status_pause
Resume:                            rm /tmp/mm_status_pause

Configuration is read from config.ini. See config.ini.example.
"""

import gi
gi.require_version("EDataServer", "1.2")
gi.require_version("ECal", "2.0")
from gi.repository import EDataServer, ECal  # noqa: E402

import os  # noqa: E402
import sys  # noqa: E402
import json  # noqa: E402
import logging  # noqa: E402
import configparser  # noqa: E402
import urllib.request  # noqa: E402
import urllib.error  # noqa: E402
from datetime import datetime, timedelta  # noqa: E402
from zoneinfo import ZoneInfo  # noqa: E402


# --------------------------------------------------------------------------- #
# Configuration loading
# --------------------------------------------------------------------------- #

CONFIG_DIR = os.path.expanduser(
    os.environ.get("MM_STATUS_CONFIG_DIR", "~/.config/mm-calendar-status")
)
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.ini")


class Config:
    """Typed view over config.ini with sane fallbacks."""

    def __init__(self, path: str):
        if not os.path.exists(path):
            raise FileNotFoundError(
                f"Config not found at {path}. "
                f"Copy config.ini.example to {path} and edit it."
            )

        parser = configparser.ConfigParser()
        parser.read(path)

        # [calendar]
        self.calendar_uid = parser.get("calendar", "uid")
        self.my_email = parser.get("calendar", "email")
        self.timezone = parser.get("calendar", "timezone", fallback="UTC")
        self.eds_connect_timeout = parser.getint(
            "calendar", "eds_connect_timeout", fallback=60
        )
        self.lookahead_minutes = parser.getint(
            "calendar", "lookahead_minutes", fallback=2
        )

        # [mattermost]
        self.mm_server = parser.get("mattermost", "server").rstrip("/")
        self.mm_user_id = parser.get("mattermost", "user_id")
        self.mm_token_file = os.path.expanduser(
            parser.get(
                "mattermost",
                "token_file",
                fallback=os.path.join(CONFIG_DIR, "mm_token"),
            )
        )
        self.http_timeout = parser.getint("mattermost", "http_timeout", fallback=10)

        # [behavior]
        self.pause_file = parser.get(
            "behavior", "pause_file", fallback="/tmp/mm_status_pause"
        )
        self.log_file = os.path.expanduser(
            parser.get(
                "behavior",
                "log_file",
                fallback=os.path.join(CONFIG_DIR, "mm_status.log"),
            )
        )

        # [keywords]
        self.ooo_keywords = self._csv(
            parser.get(
                "keywords",
                "ooo",
                fallback="out of office,ooo,pto,ask before booking,exercise,break,lunch",
            )
        )
        self.focus_keywords = self._csv(
            parser.get("keywords", "focus", fallback="focus")
        )

        # [status]
        self.ooo_emoji = parser.get("status", "ooo_emoji", fallback="shufflepartyparrot")
        self.ooo_text = parser.get("status", "ooo_text", fallback="Out of office")
        self.focus_emoji = parser.get("status", "focus_emoji", fallback="dart")
        self.focus_text = parser.get("status", "focus_text", fallback="Focus time")
        self.meeting_emoji = parser.get("status", "meeting_emoji", fallback="meet")
        # meeting_text is the event title, so no static text

        try:
            self.tz = ZoneInfo(self.timezone)
        except Exception:
            self.tz = ZoneInfo("UTC")

    @staticmethod
    def _csv(value: str) -> list[str]:
        return [v.strip().lower() for v in value.split(",") if v.strip()]


# --------------------------------------------------------------------------- #
# Mattermost API
# --------------------------------------------------------------------------- #

class Mattermost:
    def __init__(self, cfg: Config, log: logging.Logger):
        self.cfg = cfg
        self.log = log

    def _token(self) -> str:
        with open(self.cfg.mm_token_file) as f:
            return f.read().strip()

    def _request(self, method: str, path: str, body: dict | None = None) -> dict:
        url = f"{self.cfg.mm_server}/api/v4{path}"
        data = json.dumps(body).encode() if body else None
        req = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self._token()}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=self.cfg.http_timeout) as resp:
            return json.loads(resp.read())

    def set_status(self, emoji: str, text: str, expires_at_ms: int) -> None:
        self._request("PUT", f"/users/{self.cfg.mm_user_id}/status", {
            "user_id": self.cfg.mm_user_id,
            "status": "online",
        })
        expires_iso = datetime.fromtimestamp(
            expires_at_ms / 1000, tz=ZoneInfo("UTC")
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        self._request("PUT", f"/users/{self.cfg.mm_user_id}/patch", {
            "props": {
                "customStatus": json.dumps({
                    "emoji": emoji,
                    "text": text,
                    "duration": "custom",
                    "expires_at": expires_iso,
                })
            }
        })
        self.log.info(f"Status set: :{emoji}: {text} (expires {expires_at_ms})")

    def clear_status(self) -> None:
        self._request("PUT", f"/users/{self.cfg.mm_user_id}/patch", {
            "props": {"customStatus": ""}
        })
        self.log.info("Status cleared")


# --------------------------------------------------------------------------- #
# Calendar reading via EDS
# --------------------------------------------------------------------------- #

class Calendar:
    def __init__(self, cfg: Config, log: logging.Logger):
        self.cfg = cfg
        self.log = log

    def classify(self, title: str) -> str:
        t = title.lower()
        for kw in self.cfg.ooo_keywords:
            if kw in t:
                return "ooo"
        for kw in self.cfg.focus_keywords:
            if kw in t:
                return "focus"
        return "meeting"

    def _my_partstat(self, raw: str) -> str:
        """
        Parse raw VEVENT and return PARTSTAT for the configured email.
        Handles iCal line folding (continuation lines start with a space/tab).
        """
        unfolded: list[str] = []
        for line in raw.split("\n"):
            if line.startswith((" ", "\t")):
                if unfolded:
                    unfolded[-1] += line[1:]
            else:
                unfolded.append(line)

        for line in unfolded:
            line = line.strip()
            if not line.upper().startswith("ATTENDEE"):
                continue
            if self.cfg.my_email.lower() not in line.lower():
                continue
            for param in line.split(";"):
                if param.upper().startswith("PARTSTAT="):
                    return param.split("=", 1)[1].strip().upper()
        return "ACCEPTED"

    def active_event(self) -> dict | None:
        now = datetime.now(tz=self.cfg.tz)
        today = now.date()
        lookahead = now + timedelta(minutes=self.cfg.lookahead_minutes)

        registry = EDataServer.SourceRegistry.new_sync(None)
        source = registry.ref_source(self.cfg.calendar_uid)
        if source is None:
            raise RuntimeError(
                f"Calendar source {self.cfg.calendar_uid} not found in EDS"
            )

        client = ECal.Client.connect_sync(
            source, ECal.ClientSourceType.EVENTS,
            self.cfg.eds_connect_timeout, None
        )
        _, slist = client.get_object_list_as_comps_sync("#t", None)

        candidates: list[dict] = []

        for comp in slist:
            try:
                vs = comp.get_dtstart().get_value()
                ve = comp.get_dtend().get_value()
                if not vs or not ve:
                    continue

                tz_str = comp.get_dtstart().get_tzid() or "UTC"
                try:
                    event_tz = ZoneInfo(tz_str)
                except Exception:
                    event_tz = self.cfg.tz

                start = datetime(
                    vs.get_year(), vs.get_month(), vs.get_day(),
                    vs.get_hour(), vs.get_minute(), 0, tzinfo=event_tz
                )
                end = datetime(
                    ve.get_year(), ve.get_month(), ve.get_day(),
                    ve.get_hour(), ve.get_minute(), 0, tzinfo=event_tz
                )

                # active now or starting within the lookahead window
                if not (start <= lookahead and end > now):
                    continue

                # touches today (covers all-day and multi-day)
                if not (start.astimezone(self.cfg.tz).date() <= today
                        <= end.astimezone(self.cfg.tz).date()):
                    continue

                raw = comp.get_as_string()
                if self._my_partstat(raw) == "DECLINED":
                    continue

                s = comp.get_summary()
                title = s.get_value() if s else ""

                candidates.append({
                    "title": title,
                    "end_ms": int(end.timestamp() * 1000),
                    "type": self.classify(title),
                    "has_meet": "X-GOOGLE-CONFERENCE" in raw,
                })

            except Exception as e:
                self.log.debug(f"Skipping component: {e}")
                continue

        if not candidates:
            return None

        # priority: ooo > meeting > focus, then meet > no-meet, then soonest end
        priority = {"ooo": 0, "meeting": 1, "focus": 2}
        candidates.sort(key=lambda e: (
            priority.get(e["type"], 9),
            0 if e["has_meet"] else 1,
            e["end_ms"],
        ))
        return candidates[0]


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def main() -> None:
    cfg = Config(CONFIG_FILE)

    logging.basicConfig(
        filename=cfg.log_file,
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    log = logging.getLogger("mm_status")

    if os.path.exists(cfg.pause_file):
        log.info("Paused, skipping.")
        sys.exit(0)

    mm = Mattermost(cfg, log)
    cal = Calendar(cfg, log)

    try:
        event = cal.active_event()
    except Exception as e:
        log.error(f"Failed to read calendar: {e}")
        sys.exit(1)

    try:
        if event is None:
            mm.clear_status()
            return

        if event["type"] == "ooo":
            mm.set_status(cfg.ooo_emoji, cfg.ooo_text, event["end_ms"])
        elif event["type"] == "focus":
            mm.set_status(cfg.focus_emoji, cfg.focus_text, event["end_ms"])
        else:
            mm.set_status(cfg.meeting_emoji, event["title"], event["end_ms"])

    except Exception as e:
        log.error(f"Failed to set Mattermost status: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()

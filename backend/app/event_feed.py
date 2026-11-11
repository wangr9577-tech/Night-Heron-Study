"""Read learning evidence from an explicitly configured B service.

The caller's access token is forwarded to B, which must authenticate it and
filter events to that user. No client-supplied event data is accepted here.
"""

import ipaddress
import os
from urllib.parse import urlsplit

import httpx


class FeedError(Exception):
    pass


def read_events(token, course_id, cursor):
    base = os.environ.get("ZHI_B_BASE_URL", "").strip().rstrip("/")
    if not base:
        raise FeedError("learning event provider is not configured")
    parsed = urlsplit(base)
    if parsed.username or parsed.password or parsed.query or parsed.fragment or not parsed.hostname:
        raise FeedError("invalid learning event provider configuration")
    loopback = parsed.hostname.lower() == "localhost"
    try:
        loopback = loopback or ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        pass
    if parsed.scheme != "https" and not (parsed.scheme == "http" and loopback):
        raise FeedError("learning event provider requires HTTPS (except loopback)")
    params = {"limit": 100}
    if course_id:
        params["course_id"] = course_id
    if cursor:
        params["cursor"] = cursor
    try:
        with httpx.Client(timeout=10, follow_redirects=False, trust_env=False) as client:
            response = client.get(
                base + "/learning-events", params=params, headers={"Authorization": "Bearer " + token}
            )
            response.raise_for_status()
            page = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        raise FeedError("learning event provider unavailable or returned invalid JSON") from exc
    if not isinstance(page, dict) or page.get("is_demo") is True or not isinstance(page.get("events"), list):
        raise FeedError("learning event provider returned invalid or demo data")
    next_cursor = page.get("next_cursor")
    if next_cursor is not None and (
        not isinstance(next_cursor, str) or not next_cursor or len(next_cursor) > 4096
    ):
        raise FeedError("learning event provider returned an invalid cursor")
    if next_cursor is not None and next_cursor == cursor:
        raise FeedError("learning event provider cursor did not advance")
    if len(page["events"]) > 100 or any(not isinstance(event, dict) for event in page["events"]):
        raise FeedError("learning event provider returned invalid events")
    for event in page["events"]:
        if any(
            not isinstance(event.get(key), str) or not event[key] or len(event[key]) > 200
            for key in ("event_id", "user_id", "course_id")
        ):
            raise FeedError("learning event provider returned invalid identity")
        if event.get("event_type") not in (
            "practice_submitted",
            "practice_graded",
            "task_criteria_met",
        ) or not isinstance(event.get("result"), dict):
            raise FeedError("learning event provider returned invalid event type or result")
        if event["event_type"] == "practice_graded" and not isinstance(event["result"].get("passed"), bool):
            raise FeedError("learning event provider returned invalid result")
        if event["event_type"] == "task_criteria_met" and (
            not isinstance(event.get("source_task_id"), str) or not event["source_task_id"]
        ):
            raise FeedError("learning event provider returned invalid task reference")
    return page["events"], next_cursor

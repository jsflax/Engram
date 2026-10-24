#!/usr/bin/env python3
"""Post published GitHub releases to Slack, with a conservative delivery receipt.

Callers must serialize notifications for the same repository/tag. GitHub commit
statuses are an audit receipt, not an atomic lock. A pending/error receipt needs
human reconciliation because a timed-out webhook may still have been delivered.
"""

import argparse
import json
import os
import re
import sys
from urllib import error, parse, request

from slack_release_payload import build_payload


PRODUCTS = {
    "jsflax/lattice": ("Lattice", "jsflax/lattice"),
    "jsflax/latticecore": ("LatticeCore", "jsflax/LatticeCore"),
    "jsflax/engram": ("Engram", "jsflax/Engram"),
}
SAFE_RETRY = "Slack rejected delivery; safe to retry."
REJECTION_CODES = {400, 403, 404, 410, 429}
TIMEOUT = 30
MAX_RESPONSE_BYTES = 8 * 1024 * 1024


class NotificationError(Exception):
    """An actionable error that contains no remote body or credential."""


class HttpFailure(NotificationError):
    def __init__(self, status=None):
        self.status = status
        super().__init__("HTTP request failed" + (f" (status {status})." if status else "."))


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = request.build_opener(NoRedirect())


def http(url, *, method="GET", payload=None, headers=None):
    """Do one request. Never include the URL or remote body in an exception."""
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with OPENER.open(req, timeout=TIMEOUT) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            if len(raw) > MAX_RESPONSE_BYTES:
                raise NotificationError("HTTP response exceeded the size limit.")
            return response.status, raw
    except error.HTTPError as exc:
        status = exc.code
        # HTTPError owns a response stream; close it so deferred cleanup cannot
        # emit a warning containing the credential-bearing webhook URL.
        exc.close()
        raise HttpFailure(status) from None
    except (error.URLError, OSError, TimeoutError, ValueError):
        raise HttpFailure() from None


class GitHub:
    def __init__(self, repository, token):
        self.base = f"https://api.github.com/repos/{repository}"
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
            "User-Agent": "slack-release-notifier",
        }

    def call(self, path, *, payload=None):
        try:
            status, raw = http(
                self.base + path,
                method="GET" if payload is None else "POST",
                payload=payload,
                headers=self.headers,
            )
        except NotificationError as exc:
            raise NotificationError(f"GitHub API request failed. {exc}") from None
        if not 200 <= status < 300:
            raise NotificationError(f"GitHub API returned HTTP {status}.")
        try:
            return json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            raise NotificationError("GitHub API returned invalid JSON.") from None

    def receipt_states(self, sha, context):
        matching = []
        page = 1
        while True:
            entries = self.call(f"/commits/{sha}/statuses?per_page=100&page={page}")
            if not isinstance(entries, list) or any(not isinstance(item, dict) for item in entries):
                raise NotificationError("GitHub returned invalid status history.")
            matching.extend(item for item in entries if item.get("context") == context)
            if len(entries) < 100:
                return matching
            page += 1

    def set_receipt(self, sha, context, state, description, release_url):
        self.call(f"/statuses/{sha}", payload={
            "state": state,
            "context": context,
            "description": description,
            "target_url": release_url,
        })


def validate_webhook(url):
    try:
        parts = parse.urlsplit(url)
        valid = (
            parts.scheme == "https"
            and parts.netloc in {"hooks.slack.com", "hooks.slack-gov.com"}
            and re.fullmatch(r"/services/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+", parts.path)
            and not parts.query and not parts.fragment
        )
    except ValueError:
        valid = False
    if not valid:
        raise NotificationError("SLACK_WEBHOOK_URL must be a Slack HTTPS incoming webhook URL.")


def published_release(github, repository, tag):
    release = github.call("/releases/tags/" + parse.quote(tag, safe=""))
    if not isinstance(release, dict):
        raise NotificationError("GitHub returned an invalid release.")
    if release.get("draft") is not False or not release.get("published_at"):
        raise NotificationError("Only published, non-draft releases can be announced.")
    if release.get("tag_name") != tag or type(release.get("id")) is not int or release["id"] <= 0:
        raise NotificationError("GitHub returned a mismatched release identity.")
    url = release.get("html_url")
    if not isinstance(url, str):
        raise NotificationError("GitHub release URL is missing.")
    try:
        parts = parse.urlsplit(url)
        expected = f"/{repository}/releases/tag/{tag}"
        path = parse.unquote(parts.path)
        valid = (
            parts.scheme == "https" and parts.netloc == "github.com"
            and path[:len(repository) + 1].lower() == f"/{repository}".lower()
            and path[len(repository) + 1:] == expected[len(repository) + 1:]
            and not parts.query and not parts.fragment
        )
    except ValueError:
        valid = False
    if not valid:
        raise NotificationError("GitHub release URL does not match this repository and tag.")
    if release.get("body") is not None and not isinstance(release["body"], str):
        raise NotificationError("GitHub returned invalid release notes.")
    return release


def notify(tag, *, dry_run=False, environ=None):
    env = os.environ if environ is None else environ
    supplied_repository = env.get("GITHUB_REPOSITORY", "")
    product_config = PRODUCTS.get(supplied_repository.lower())
    if product_config is None:
        raise NotificationError("GITHUB_REPOSITORY is not an approved release repository.")
    product, repository = product_config
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
    if not token:
        raise NotificationError("GH_TOKEN or GITHUB_TOKEN is required.")
    if not tag or len(tag) > 255 or any(ord(character) < 32 for character in tag):
        raise NotificationError("A valid release tag is required.")
    webhook = env.get("SLACK_WEBHOOK_URL", "")
    if not dry_run:
        validate_webhook(webhook)

    github = GitHub(repository, token)
    release = published_release(github, repository, tag)
    icon_url = None if product == "Engram" else (
        f"https://raw.githubusercontent.com/{repository}/main/.github/assets/release-icon.png"
    )
    payload = build_payload(product, tag, release["html_url"], release.get("body") or "", icon_url)
    if dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return "dry-run"

    commit = github.call("/commits/" + parse.quote(tag, safe=""))
    sha = commit.get("sha") if isinstance(commit, dict) else None
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", sha):
        raise NotificationError("GitHub did not resolve the release tag to a commit.")
    context = f"slack-release/{release['id']}"
    statuses = github.receipt_states(sha, context)
    if any(item.get("state") == "success" for item in statuses):
        print(f"{product} {tag}: Slack notification already delivered; skipping.")
        return "already-delivered"
    if statuses and not (
        statuses[0].get("state") == "failure" and statuses[0].get("description") == SAFE_RETRY
    ):
        raise NotificationError(
            "A prior Slack delivery receipt is unresolved. Check #engram and reconcile "
            f"the {context} commit status before retrying; no message was sent."
        )

    github.set_receipt(sha, context, "pending", "Slack delivery started; reconcile before retrying.", release["html_url"])
    try:
        status, response = http(webhook, method="POST", payload=payload, headers={
            "Content-Type": "application/json; charset=utf-8",
            "User-Agent": "slack-release-notifier",
        })
    except HttpFailure as exc:
        if exc.status in REJECTION_CODES:
            github.set_receipt(sha, context, "failure", SAFE_RETRY, release["html_url"])
            raise NotificationError(f"Slack rejected the notification (HTTP {exc.status}); fix the cause and retry.") from None
        raise NotificationError(
            "Slack delivery could not be confirmed; the receipt remains pending. "
            f"Check #engram and reconcile {context} before retrying."
        ) from None
    except NotificationError:
        raise NotificationError(
            "Slack delivery could not be confirmed; the receipt remains pending. "
            f"Check #engram and reconcile {context} before retrying."
        ) from None
    if status != 200 or response != b"ok":
        raise NotificationError(
            "Slack did not return its exact success acknowledgement; the receipt remains pending. "
            f"Check #engram and reconcile {context} before retrying."
        )
    try:
        github.set_receipt(sha, context, "success", "Slack release notification delivered.", release["html_url"])
    except NotificationError:
        raise NotificationError(
            "Slack accepted the notification, but saving its success receipt failed. "
            f"Do not resend; reconcile {context} on the release commit."
        ) from None
    print(f"{product} {tag}: Slack notification delivered.")
    return "delivered"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="Published GitHub release tag")
    parser.add_argument("--dry-run", action="store_true", help="Print the payload without sending or writing receipts")
    args = parser.parse_args(argv)
    try:
        notify(args.tag, dry_run=args.dry_run)
    except NotificationError as exc:
        print(f"Release notification failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

import contextlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
from urllib import error

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import notify_slack_release as notifier


SHA = "a" * 40
WEBHOOK = "https://hooks.slack.com/services/T_TEST/B_TEST/secret_webhook"
TOKEN = "secret_github_token"
ENV = {"GITHUB_REPOSITORY": "jsflax/lattice", "GH_TOKEN": TOKEN, "SLACK_WEBHOOK_URL": WEBHOOK}
RELEASE = {
    "id": 123,
    "tag_name": "2.2.5",
    "draft": False,
    "published_at": "2026-10-23T00:00:00Z",
    "body": "### Fixed\n- Published release body, not a local changelog.",
    "html_url": "https://github.com/jsflax/lattice/releases/tag/2.2.5",
}


class Server:
    def __init__(self, *, release=None, statuses=None, slack=None, fail_receipt=None):
        self.release = RELEASE.copy() if release is None else release
        self.statuses = [[]] if statuses is None else statuses
        self.slack = (200, b"ok") if slack is None else slack
        self.fail_receipt = fail_receipt
        self.calls = []

    def __call__(self, url, *, method="GET", payload=None, headers=None):
        self.calls.append((url, method, payload, headers))
        if url == WEBHOOK:
            if isinstance(self.slack, Exception):
                raise self.slack
            return self.slack
        if "/releases/tags/" in url:
            data = self.release
        elif method == "POST" and "/statuses/" in url:
            if payload["state"] == self.fail_receipt:
                raise notifier.HttpFailure(503)
            data = {"state": payload["state"]}
        elif "/statuses?" in url:
            page = int(url.rsplit("page=", 1)[1])
            data = self.statuses[page - 1]
        elif "/commits/" in url:
            data = {"sha": SHA}
        else:
            raise AssertionError("Unexpected HTTP request")
        return 200, json.dumps(data).encode()

    def webhook_calls(self):
        return [item for item in self.calls if item[0] == WEBHOOK]

    def receipts(self):
        return [item[2]["state"] for item in self.calls if item[1] == "POST" and "/statuses/" in item[0]]


def receipt(state, description=""):
    return {"context": "slack-release/123", "state": state, "description": description}


class NotifyReleaseTests(unittest.TestCase):
    def run_notifier(self, server, *, env=None, dry_run=False, tag="2.2.5"):
        with mock.patch.object(notifier, "http", side_effect=server), contextlib.redirect_stdout(io.StringIO()):
            return notifier.notify(tag, environ=ENV if env is None else env, dry_run=dry_run)

    def test_delivers_published_body_and_records_receipts_in_order(self):
        server = Server()
        with mock.patch.object(notifier, "build_payload", return_value={"text": "formatted"}) as build:
            self.assertEqual(self.run_notifier(server), "delivered")
        build.assert_called_once_with(
            "Lattice", "2.2.5", RELEASE["html_url"], RELEASE["body"],
            "https://raw.githubusercontent.com/jsflax/lattice/main/.github/assets/release-icon.png",
        )
        self.assertEqual([item[1] for item in server.calls], ["GET", "GET", "GET", "POST", "POST", "POST"])
        self.assertEqual(server.receipts(), ["pending", "success"])
        self.assertEqual(server.calls[3][2]["context"], "slack-release/123")
        self.assertEqual(server.calls[4][0], WEBHOOK)
        self.assertNotIn("Authorization", server.calls[4][3])
        self.assertEqual(server.calls[0][3]["Authorization"], f"Bearer {TOKEN}")

    def test_dry_run_only_fetches_release_and_emits_json(self):
        server = Server()
        output = io.StringIO()
        with mock.patch.object(notifier, "http", side_effect=server), contextlib.redirect_stdout(output):
            result = notifier.notify("2.2.5", dry_run=True, environ={"GITHUB_REPOSITORY": "jsflax/lattice", "GITHUB_TOKEN": TOKEN})
        self.assertEqual(result, "dry-run")
        payload = json.loads(output.getvalue())
        self.assertIn("Lattice", payload["text"])
        self.assertEqual(len(server.calls), 1)
        self.assertEqual(server.calls[0][1], "GET")

    def test_all_repository_products_and_icons(self):
        for repo, product, canonical in [
            ("jsflax/lattice", "Lattice", "jsflax/lattice"),
            ("jsflax/LatticeCore", "LatticeCore", "jsflax/LatticeCore"),
            ("jsflax/Engram", "Engram", "jsflax/Engram"),
        ]:
            with self.subTest(repo=repo):
                release = dict(RELEASE, html_url=f"https://github.com/{repo}/releases/tag/2.2.5")
                server = Server(release=release)
                with mock.patch.object(notifier, "build_payload", return_value={}) as build:
                    self.run_notifier(server, env=dict(ENV, GITHUB_REPOSITORY=repo), dry_run=True)
                self.assertEqual(build.call_args.args[0], product)
                self.assertEqual(build.call_args.args[4], None if product == "Engram" else f"https://raw.githubusercontent.com/{canonical}/main/.github/assets/release-icon.png")

    def test_refuses_draft_or_unpublished_release(self):
        for change in [{"draft": True}, {"published_at": None}, {"draft": None}]:
            server = Server(release=dict(RELEASE, **change))
            with self.subTest(change=change), self.assertRaisesRegex(notifier.NotificationError, "published"):
                self.run_notifier(server)
            self.assertFalse(server.webhook_calls())

    def test_refuses_wrong_repository_without_http(self):
        server = Server()
        with self.assertRaisesRegex(notifier.NotificationError, "approved"):
            self.run_notifier(server, env=dict(ENV, GITHUB_REPOSITORY="attacker/lattice"))
        self.assertEqual(server.calls, [])

    def test_refuses_mismatched_release_identity_or_url(self):
        changes = [
            {"tag_name": "different"}, {"id": True}, {"id": 0},
            {"html_url": "https://attacker.example/jsflax/lattice/releases/tag/2.2.5"},
            {"html_url": "https://github.com/attacker/lattice/releases/tag/2.2.5"},
            {"html_url": RELEASE["html_url"] + "?redirect=elsewhere"},
            {"html_url": RELEASE["html_url"] + "extra"},
        ]
        for change in changes:
            server = Server(release=dict(RELEASE, **change))
            with self.subTest(change=change), self.assertRaises(notifier.NotificationError):
                self.run_notifier(server)
            self.assertFalse(server.webhook_calls())

    def test_webhook_allowlist_rejects_redirects_and_lookalikes(self):
        for url in [
            "http://hooks.slack.com/services/A/B/C",
            "https://hooks.slack.com.attacker.example/services/A/B/C",
            "https://user@hooks.slack.com/services/A/B/C",
            "https://hooks.slack.com:443/services/A/B/C",
            "https://hooks.slack.com/services/A/B/C?secret=other",
            "https://hooks.slack.com/services/A/B/C#fragment",
            "https://hooks.slack.com/other/A/B/C", "",
        ]:
            server = Server()
            with self.subTest(url=url), self.assertRaisesRegex(notifier.NotificationError, "incoming webhook"):
                self.run_notifier(server, env=dict(ENV, SLACK_WEBHOOK_URL=url))
            self.assertFalse(server.calls)
        notifier.validate_webhook("https://hooks.slack-gov.com/services/A/B/C")

    def test_success_dedupes_even_if_older_than_one_page(self):
        unrelated = [{"context": "ci", "state": "success"}] * 100
        server = Server(statuses=[unrelated, [receipt("success")]])
        self.assertEqual(self.run_notifier(server), "already-delivered")
        self.assertEqual(len([item for item in server.calls if "/statuses?" in item[0]]), 2)
        self.assertFalse(server.webhook_calls())
        self.assertFalse(server.receipts())

    def test_old_success_still_dedupes_when_newer_receipt_is_pending(self):
        server = Server(statuses=[[receipt("pending"), receipt("success")]])
        self.assertEqual(self.run_notifier(server), "already-delivered")
        self.assertFalse(server.webhook_calls())

    def test_pending_error_and_untrusted_failure_refuse_resend(self):
        for state in ["pending", "error", "failure", "unknown"]:
            server = Server(statuses=[[receipt(state)]])
            with self.subTest(state=state), self.assertRaisesRegex(notifier.NotificationError, "unresolved"):
                self.run_notifier(server)
            self.assertFalse(server.webhook_calls())
            self.assertFalse(server.receipts())

    def test_known_rejection_failure_can_retry(self):
        server = Server(statuses=[[receipt("failure", notifier.SAFE_RETRY), receipt("pending")]])
        self.assertEqual(self.run_notifier(server), "delivered")
        self.assertEqual(server.receipts(), ["pending", "success"])

    def test_pending_receipt_must_succeed_before_sending(self):
        server = Server(fail_receipt="pending")
        with self.assertRaisesRegex(notifier.NotificationError, "GitHub API"):
            self.run_notifier(server)
        self.assertFalse(server.webhook_calls())

    def test_known_slack_rejection_writes_safe_retry_receipt(self):
        server = Server(slack=notifier.HttpFailure(400))
        with self.assertRaisesRegex(notifier.NotificationError, "rejected.*400"):
            self.run_notifier(server)
        self.assertEqual(server.receipts(), ["pending", "failure"])
        self.assertEqual(server.calls[-1][2]["description"], notifier.SAFE_RETRY)

    def test_ambiguous_network_or_server_error_never_retries(self):
        for error in [notifier.HttpFailure(), notifier.HttpFailure(500)]:
            server = Server(slack=error)
            with self.subTest(error=error), self.assertRaisesRegex(notifier.NotificationError, "remains pending"):
                self.run_notifier(server)
            self.assertEqual(server.receipts(), ["pending"])
            self.assertEqual(len(server.webhook_calls()), 1)

    def test_requires_exact_slack_acknowledgement(self):
        for response in [(200, b"ok\n"), (200, b"not ok"), (201, b"ok")]:
            server = Server(slack=response)
            with self.subTest(response=response), self.assertRaisesRegex(notifier.NotificationError, "exact success"):
                self.run_notifier(server)
            self.assertEqual(server.receipts(), ["pending"])
            self.assertEqual(len(server.webhook_calls()), 1)

    def test_success_receipt_failure_does_not_resend(self):
        server = Server(fail_receipt="success")
        with self.assertRaisesRegex(notifier.NotificationError, "accepted.*Do not resend"):
            self.run_notifier(server)
        self.assertEqual(len(server.webhook_calls()), 1)

    def test_http_transport_sanitizes_secret_bearing_failures(self):
        for failure in [
            error.URLError(f"failed {WEBHOOK} {TOKEN}"),
            error.HTTPError(WEBHOOK, 403, f"forbidden {TOKEN}", {}, None),
        ]:
            with self.subTest(kind=type(failure)), mock.patch.object(notifier.OPENER, "open", side_effect=failure):
                with self.assertRaises(notifier.HttpFailure) as caught:
                    notifier.http(WEBHOOK, method="POST", payload={})
            self.assertNotIn(WEBHOOK, str(caught.exception))
            self.assertNotIn(TOKEN, str(caught.exception))

    def test_http_transport_disables_redirects_and_has_timeout(self):
        self.assertIsNone(notifier.NoRedirect().redirect_request(None, None, 302, "", {}, "https://elsewhere.example"))
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b"ok"
        with mock.patch.object(notifier.OPENER, "open", return_value=response) as open_request:
            self.assertEqual(notifier.http(WEBHOOK, method="POST", payload={"text": "hello"}), (200, b"ok"))
        self.assertEqual(open_request.call_args.kwargs["timeout"], 30)
        self.assertEqual(json.loads(open_request.call_args.args[0].data), {"text": "hello"})

    def test_cli_failure_contains_no_credentials(self):
        server = Server(slack=notifier.HttpFailure(500))
        output = io.StringIO()
        with mock.patch.dict(notifier.os.environ, ENV, clear=True), mock.patch.object(notifier, "http", side_effect=server), contextlib.redirect_stderr(output):
            self.assertEqual(notifier.main(["--tag", "2.2.5"]), 1)
        self.assertIn("remains pending", output.getvalue())
        self.assertNotIn(WEBHOOK, output.getvalue())
        self.assertNotIn(TOKEN, output.getvalue())


if __name__ == "__main__":
    unittest.main()

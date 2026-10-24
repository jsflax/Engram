# Slack release announcements

Published releases are announced to Canary Slack's #engram channel using the
repository secret `SLACK_WEBHOOK_URL`. Configure it for that channel; never commit
or print the URL. The shared incoming webhook retains its Slack app identity.
Lattice and LatticeCore identify themselves with their product icons in the card.

The release workflow calls `slack-release.yml` directly after publication because
GitHub suppresses new release-event runs for publications made by `GITHUB_TOKEN`.
Preserve this call when replacing the release pipeline. Manually published
releases also trigger the notifier. Failed/draft releases are not announced as
successful releases. Notification failure does not roll back an existing release.

The notifier reads the published GitHub release body, joins prose soft wraps,
preserves paragraphs/lists/code, and formats the same heading, categories, bullets,
and View Release button as Engram. Large notes are split within Slack's limits;
if the block budget is exhausted, the card links to the complete notes.

To announce an existing release or retry a known failure, dispatch **Slack release
announcement** on `main` with the existing tag. No build, tag, or release is
created. Notification code is fetched from trusted `main`, including for older
tags. The job requires `contents: read` and `statuses: write`.

A commit status named `slack-release/<GitHub release ID>` records delivery on the
tag's resolved commit. Successful retries are skipped. A pending/error receipt
means delivery may have happened: inspect Slack and the run before changing the
receipt. If the message exists, mark the same status context successful. Only if
you have established it was not delivered should you mark it `failure` with the
exact description `Slack rejected delivery; safe to retry.` and retry. This
explicit marker distinguishes a reviewed safe retry from an arbitrary failed
status.
There is no atomic transaction spanning Slack and GitHub; ambiguous failures are
held for inspection instead of blindly posting duplicates.

Local tests (Python standard library only; no native build):

```sh
python3 -B -m unittest discover -s .github/scripts/tests -v
```

For a preview without posting or writing a receipt, set `GITHUB_REPOSITORY` and
`GH_TOKEN` and run `.github/scripts/notify_slack_release.py --tag TAG --dry-run`
with Python 3. The webhook is not required for previews.

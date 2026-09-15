# Release train

Each repository keeps its own SemVer 2.0.0 sequence. Orbital and Engram use `v` tags; Lattice and LatticeCore use bare version tags. `policy.json` records this repository's gates and dependencies. The Python protocol and tests are identical vendored copies in all four repositories; change them together and keep their SHA-256 hashes equal. No dependency pins or product versions are changed by installing this automation.

## What progresses automatically

The release owner selects an explicit version and exact, adopted `main` commit. The protocol checks that commit, clean source, version monotonicity, changelog, lockfile consistency, published dependency tag revisions and required prior CI. It dispatches the **existing release workflow** directly, which runs the product's tests and packaging. Only the publication job creates the GitHub release/tag after those gates pass. Repeated dispatch calls reconcile the same version and source commit instead of starting another build. Promoting a prerelease to stable uses its own version identity.

The protocol never infers that source preparation or test discovery means a product passed tests. A changed commit, dependency, package or failed check requires a new validation. A missing credential or dependency stops before compilation. No status text or manifest field becomes a shell command.

Orbital has a separate allocated local build/sign/notarize pipeline. `scripts/release.sh prepare` creates the package and a receipt; `publish` verifies the package against retained native evidence and performs no rebuild. See the Orbital section below.

## Version and changelog preparation

From an isolated checkout, fetch current `main` and tags, inspect the actual adopted changes and select the bump:

```sh
python3 release-train/release_train.py suggest --bump minor --channel stable
python3 release-train/release_train.py notes --version 1.8.0 --output /tmp/release-notes.md
```

Major = incompatible public API; minor = compatible additions; patch = compatible fixes. Respect Lattice's existing `VERSIONING.md` API scope/exemptions. Before 1.0, review compatibility deliberately and explain breaking changes. The tool does not guess compatibility from commit prefixes. Review notes and add them to `CHANGELOG.md` where configured; update app marketing/build versions as applicable in the same release-preparation change. That change must land and pass its required CI before it is a candidate. Do not auto-merge unrelated private worktrees or substitute their stages for canonical Git source.

Review channels use `alpha.N`, `beta.N` or `rc.N`; Lattice's existing preflight supports `rc.N`. Stable appcasts and Homebrew are only updated by stable releases. Published versions, tags and assets are immutable to this owner. Partial or failed publication is inspected and reconciled explicitly, never overwritten by retry.

## Candidate and hosted release

Run the following **after** the version/dependency change is adopted, from the clean exact commit. Keep receipts outside the source checkout. Replace the sample values with the owner-selected version and full candidate SHA:

```sh
python3 release-train/release_train.py candidate \
  --version 1.8.0 --expected-sha FULL_40_CHARACTER_MAIN_SHA \
  --output /tmp/lattice-candidate.json
python3 release-train/release_train.py dispatch \
  --version 1.8.0 --expected-sha FULL_40_CHARACTER_MAIN_SHA
```

`dispatch` starts the configured GitHub-hosted release workflow after candidate selection. Ordinary hosted CI and these established hosted release gates are separate from the local native resource queue. Local builds, signing, GUI and model checks still require the existing ROOT allocation. Lattice calls its existing `ci.yml` plus release preflight; LatticeCore reuses its macOS, Linux and C ABI definitions; Engram runs its Linux portable build, existing native tests, app/CLI signing, notarization and appcast generation. The exact `GITHUB_SHA` is the source of every job. Publication rechecks that source and dependency selection. If `main` advances during a run, publication waits for the new candidate instead of silently shipping an old one.

Direct `workflow_dispatch` avoids depending on a tag pushed with `GITHUB_TOKEN` triggering another workflow. Legacy tag pushes still enter the same gates. The newly added dispatch path does not send Slack/email notifications. Existing Engram tag-push notifications retain their existing entry point; the release owner uses dispatch.

A successful hosted release uploads `release-receipt.json`, binding the exact source, candidate digest, artifact SHA-256/byte counts and Actions run/attempt. Source-library releases have an empty additional artifact set; GitHub supplies their tagged source archives. App releases require the complete configured signed distribution artifacts. A GitHub source tag used by SwiftPM is checked by exact tag-to-commit resolution; a GitHub Release web page is not required for a dependency's already published source tag.

## Orbital local prepare / validate / publish

Orbital's local sibling dependencies must be clean Git checkouts whose exact commits are published and available from their GitHub origins. The dependency snapshot includes the root and Kit lockfiles plus the current MLX and visual helper siblings. A private non-Git stage cannot pass. If the adopted graph changes, update `policy.json` and the native release integration together; never remove a required dependency just to make preflight green.

```sh
python3 release-train/release_train.py candidate \
  --version 0.2.0-rc.1 --expected-sha FULL_40_CHARACTER_MAIN_SHA \
  --output /absolute/receipts/orbital-candidate.json
export ORBITAL_RELEASE_CANDIDATE=/absolute/receipts/orbital-candidate.json
scripts/release.sh prepare
```

The app plist keeps Apple's three-number marketing version (for this example `0.2.0`) and a monotonically increasing build number. The SemVer prerelease stays in the tag and artifact name. Prepare retains the existing inside-out signing, signed-loop probe, DMG, notarization, stapling and Sparkle steps. It records the DMG, appcast, App/Loop/MCP/visual executable and loop-buildstamp hashes in `dist/release-receipt.json`.

The native validation owner then runs the allocated native tests and the real room/provider/artifact workflow against **that prepared package** and writes a separate native receipt. Its structure is:

```json
{
  "schemaVersion": 1,
  "sourceSha": "FULL_40_CHARACTER_MAIN_SHA",
  "packageReceiptDigest": "SHA256_OF_CANONICAL_PACKAGE_RECEIPT_JSON",
  "checks": [
    {
      "name": "native-tests",
      "result": "passed",
      "evidence": {"path": "/absolute/evidence/native-tests.json", "sha256": "SHA256"}
    },
    {
      "name": "matched-app-loop-mcp",
      "result": "passed",
      "evidence": {"path": "/absolute/evidence/package-provenance.json", "sha256": "SHA256"}
    },
    {
      "name": "room-provider-artifact-workflow",
      "result": "passed",
      "evidence": {"path": "/absolute/evidence/live-workflow.json", "sha256": "SHA256"}
    }
  ]
}
```

`prepare` prints the canonical package-receipt digest. Each named check needs exactly one passing retained evidence file with a matching hash. The designated native validation owner is responsible for the truth of those results; this JSON is an owner attestation, not a cryptographic claim that arbitrary text proves a GUI workflow. Do not synthesize passing receipts from screenshots, task summaries, source tests or discovery counts. Keep them private with the review build until the publication owner consumes them.

```sh
export ORBITAL_NATIVE_RECEIPT=/absolute/receipts/orbital-native.json
scripts/release.sh publish
```

Publish verifies source, dependencies, CI, package paths/hashes and native evidence again, tags the explicit SHA, then publishes. It never rebuilds after the native evidence. A stable appcast commit is last. Prerelease appcasts remain release assets and do not replace the stable update feed. If release publication succeeds but the later appcast commit fails, report partial completion and repair only the appcast commit; the existing release must not be recreated.

## Durable owner handoff

The recurring release owner reads repository/workflow status and the existing Conductor/ROOT acceptance receipts. Preserve one selected candidate per repository with these fields in the coordinating train state:

- repository, version, channel and full source SHA;
- candidate receipt path/digest and exact dependency selection;
- current phase: source, preflight, validation, packaging, publication;
- actual workflow run ID/attempt or allocated local owner;
- concrete missing/failed gate and evidence path/URL;
- published release URL only after GitHub confirms it.

On each follow-up: reconcile an existing run first; do not start duplicate work. Advance only the recorded candidate through its configured hosted gates, or with the existing ROOT allocation for local native work. Pass `dispatch` output to the status owner as facts. On a failed run, retain its identity and root cause; a retry of unchanged source uses that same run's explicit rerun mechanism after its failure is resolved; changed source is a new validated candidate. Never create a new version merely to bypass a failed gate. No additional polling daemon is installed by this protocol.

## Validation

```sh
python3 -m unittest discover -s release-train -p 'test_*.py'
```

These tests exercise SemVer precedence, invalid input, exact CI selection, dependency mismatch, candidate identity, native receipt binding, publication paths and artifact tampering, including an end-to-end temporary local Git repository. They do not build any product. `release-train-checks.yml` runs only these Python checks. Native/platform behavior is validated by the existing release pipelines, not by this test suite.

Sources: [Semantic Versioning 2.0.0](https://semver.org/), [GitHub workflow triggering and token behavior](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).

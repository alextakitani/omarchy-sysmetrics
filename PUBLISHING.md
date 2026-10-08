# Publishing

System Metrics is listed in the [Omarchy plugin marketplace](https://plugins.omarchy.org)
under the id `takitani.sysmetrics`. The listing is a snapshot of one exact commit:
pushing to `main` does **not** update it. The marketplace only shows the new
version after a verification issue for that commit is approved.

References: the marketplace's [publishing guide](https://plugins.omarchy.org/publish.html)
and its [SUBMISSION.md](https://github.com/omacom/omarchy-plugin-marketplace/blob/main/SUBMISSION.md).

## What the listing shows

- `manifest.json`: `name`, `author`, `license`, `version`, `description`.
- `preview.png` in the repo root becomes the banner. The marketplace makes the card
  and detail images itself, so it needs no resizing (input limit: 50 MB / 40 MP).
- Category **System**, tags **bar, quickshell, system**. These were set on the
  original submission, not in the manifest.

## Releasing an update

1. Bump `version` in `manifest.json`, move the `Unreleased` entries in `CHANGELOG.md`
   and `CHANGELOG.pt-BR.md` under the new version, and run `omarchy plugin validate`.
2. Commit, push `main`, then tag and release:

   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   gh release create vX.Y.Z --title "System Metrics X.Y.Z" --notes-file <notes>
   ```

3. Ask the marketplace to publish that exact commit. Use the
   [Plugin verification form](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml)
   with **Verify and publish a newer upstream commit**, or the CLI:

   ```bash
   cat > /tmp/sysmetrics-verify.md <<EOF
   ### Verification action

   Verify and publish a newer upstream commit

   ### Plugin ID

   takitani.sysmetrics

   ### Repository URL

   https://github.com/alextakitani/omarchy-sysmetrics

   ### Target commit

   $(git rev-parse origin/main)

   ### Verification acknowledgment

   - [x] I understand that only the exact target commit can become a verified marketplace snapshot and that verification is not a security audit.

   ### Standard installation acknowledgment

   - [ ] I confirm that this listed root plugin supports the standard Omarchy installation path and does not require manual setup.
   EOF

   gh issue create --repo omacom/omarchy-plugin-marketplace \
     --title "[Verify]: System Metrics" --body-file /tmp/sysmetrics-verify.md
   ```

   The target must be the full 40-character SHA of the current `HEAD` of `main`.
   If anything lands after you file the issue, the listing shows "Update unverified".

4. A bot runs validation and the **Automated Security Baseline** on that commit,
   then comments on the issue. A maintainer applies `approved-and-verified`, and that
   publishes the new snapshot. If validation fails, fix the repo and **edit the same
   issue**, which re-runs it. Do not open a duplicate.

## History

| Issue | Kind | Commit | Outcome |
|---|---|---|---|
| [#2485](https://github.com/omacom/omarchy-plugin-marketplace/issues/2485) | First submission (`[Plugin]:`) | — | Listed 2026-08-28 |
| [#8505](https://github.com/omacom/omarchy-plugin-marketplace/issues/8505) | Update (`[Verify]:`) | `aa946c9` (1.4.0) | `security-review-required`, then approved 2026-10-01 |

The first submission (`[Plugin]: System Metrics`) is needed only once. Its maintainer
notes (dependencies: only `df`; permissions: world-readable `/proc` and `/sys` only;
hardware discovery; no config needed) are worth reusing if a reviewer asks again.

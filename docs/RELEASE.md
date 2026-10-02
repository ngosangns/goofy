# Releasing Goofy (ngosangns/goofy)

In-app updates come from [ngosangns/goofy releases](https://github.com/ngosangns/goofy/releases). `goofy/AppDelegate.swift` constructs AppUpdater with `owner: "ngosangns"`, `repo: "goofy"`, and `releasePrefix: "Goofy"`. Upstream [danielbuechele/goofy](https://github.com/danielbuechele/goofy) releases are not what this fork installs.

AppUpdater 0.2.0 (`https://github.com/s1ntoneli/AppUpdater.git`) calls `GET /repos/ngosangns/goofy/releases` and keeps a release when all of these hold:

- The release is published. Drafts are absent from that API. `prerelease` must be false (`allowPrereleases` stays false).
- `tag_name` is strict semver `MAJOR.MINOR.PATCH`. The parser does not strip a leading `v`, and a failed parse becomes `0.0.0`, which will never be newer than the installed app. Publish the tag as `4.0.161`.
- An asset is named `Goofy-<tag>.zip` (case-insensitive, extension `.zip`) and its `content_type` is `application/zip`.
- The zip contains a top-level `Goofy.app`, built with `zip -r -y`. `ditto` stores `com.apple.provenance` as AppleDouble `._*` files. AppUpdater extracts with `/usr/bin/unzip`, those files land inside the bundle, and the signature breaks.
- The running app and the download share the same code-signing authority (`Authority=` from `codesign -dvvv`). Ad-hoc signatures have no authority. AppUpdater then refuses the install unless `skipCodeSignValidation` is set, and this app does not set it. A Developer ID build updates a Developer ID install. An ad-hoc zip is still uploaded so the file is available to download by hand.

`CFBundleShortVersionString` of the shipped app is the release tag. The workflow passes `MARKETING_VERSION` at archive time, so a tag can ship even when `project.pbxproj` still has an older marketing version. Bump and commit first so the git tag and the source agree.

## Cut a release

1. Bump the version. This only edits `goofy.xcodeproj/project.pbxproj`:

   ```bash
   bash scripts/increment_build.sh
   # prints: Build NNN, version X.Y.Z
   ```

2. Commit that bump, then tag the same commit. The tag has no `v` prefix.

   ```bash
   git add goofy.xcodeproj/project.pbxproj
   git commit -m "vX.Y.Z"
   git tag X.Y.Z
   git push origin HEAD
   git push origin X.Y.Z
   ```

   Pushing `X.Y.Z` or `vX.Y.Z` runs [`.github/workflows/release.yml`](../.github/workflows/release.yml) on `macos-26` (Xcode 26; the project is `objectVersion` 77). A `v` tag is accepted and the GitHub Release is created on the unprefixed tag, which is the tag AppUpdater reads.

3. Or run the workflow by hand: Actions → Release → Run workflow.

   - `version`: `MAJOR.MINOR.PATCH`, optional leading `v`. Empty uses `MARKETING_VERSION` in the project.
   - `signing`: `auto` (default), `adhoc`, or `developer-id`.

The release title is the version. Notes are generated from commits. The asset is `Goofy-X.Y.Z.zip`. The job fails if the release is left as a draft or prerelease, or if the asset content type is not `application/zip`.

`scripts/increment_build.sh` is unchanged. The workflow does not commit a version bump.

## Signing

`auto` uses Developer ID when the certificate secrets below are all present. Otherwise it archives with signing disabled, ad-hoc signs `Goofy.app` (`codesign --sign -`), and still uploads the zip. Choosing `developer-id` fails the job when those secrets are missing. Choosing `adhoc` always builds the ad-hoc zip.

Notarization runs only when the Developer ID certificate and the notarytool secrets are both set. A Developer ID zip without notarization is still uploaded. Gatekeeper may prompt on first launch. AppUpdater can still install it over a build signed by the same Developer ID.

The committed `ExportOptions.plist` is for the local publish skill and still names team `K5C6E7A2D6`. CI writes its own export options from `APPLE_TEAM_ID` and does not read that plist.

### Secrets

`GITHUB_TOKEN` is provided by Actions. The workflow sets `contents: write` so it can create the release and the unprefixed tag. No extra token secret is required.

Set these on [ngosangns/goofy](https://github.com/ngosangns/goofy/settings/secrets/actions) for a notarized Developer ID release. Leave them unset to keep publishing ad-hoc zips.

| Secret | Used when | Value |
| --- | --- | --- |
| `APPLE_CERTIFICATE_P12` | Developer ID | Base64 of a **Developer ID Application** `.p12` (not Apple Development). `base64 -i Certificates.p12 \| pbcopy` |
| `APPLE_CERTIFICATE_PASSWORD` | Developer ID | Password for that `.p12` |
| `APPLE_TEAM_ID` | Developer ID | 10-character Apple Team ID. Written into the export options and used as `DEVELOPMENT_TEAM` |
| `DEVELOPMENT_TEAM` | Optional | Overrides `APPLE_TEAM_ID` when the signing team id differs |
| `APPLE_API_KEY` | Notarization | App Store Connect API key (`.p8`). Paste the PEM, including `BEGIN PRIVATE KEY`, or set the base64 of that file |
| `APPLE_API_KEY_ID` | Notarization | Key id. The filename is `AuthKey_<KEY_ID>.p8` |
| `APPLE_API_ISSUER` | Notarization | Issuer UUID from App Store Connect |

Create the API key in App Store Connect → Users and Access → Integrations → App Store Connect API. The role needs access to notarize (Developer or Admin).

## Ad-hoc vs notarized

| | Ad-hoc CI zip | Developer ID, not notarized | Developer ID + notarized |
| --- | --- | --- | --- |
| Secrets | none | certificate + team | certificate + team + API key |
| Gatekeeper | often blocked | prompt on first launch | normal launch |
| AppUpdater install | refused (no `Authority=`) | installs over the same Developer ID | installs over the same Developer ID |

Hand-install an ad-hoc zip by copying `Goofy.app` out of the archive into `/Applications` after Gatekeeper is bypassed (right-click → Open). The next Developer ID release will not auto-update that copy, because the authorities differ. Install one Developer ID build first, then AppUpdater can move that install forward.

A Mac that already has the Developer ID certificate and a `notarytool` keychain profile can still ship with [`.claude/skills/publish/SKILL.md`](../.claude/skills/publish/SKILL.md). That path uses `zip -r -y` and `gh release create` the same way. Do not push tags or open pull requests against `danielbuechele/goofy`.

## What the workflow does

1. Resolve the version from the tag, the workflow input, or `MARKETING_VERSION`.
2. Skip if that tag already has a published `Goofy-<version>.zip` with content type `application/zip`.
3. Archive the `goofy` scheme, Release, with `MARKETING_VERSION` set to the release version.
4. Export with Developer ID, or ad-hoc sign the archived app.
5. Notarize and staple when the API key secrets are set.
6. `scripts/make_release_zip.sh` runs `zip -r -y`, unzips with `/usr/bin/unzip`, rejects `._*` members, checks the short version, and runs `codesign --verify --deep --strict`.
7. `gh release create` attaches the zip. Title is the version. The release is published, not a draft, not a prerelease, and marked latest.

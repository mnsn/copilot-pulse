# Security policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/mnsn/copilot-pulse/security/advisories/new),
not in a public issue.

Describe what's affected, how to reproduce it and the impact you expect. This is a personal
project maintained in spare time, so a reply may take a few days.

## Scope

Copilot Pulse only reads the GitHub Copilot app's files under `~/.copilot`. Its only network
requests are for its own updates, from this project's GitHub releases. Worth reporting:

- any way it could change or corrupt the Copilot app's data, or keep the app from saving it,
- any way it could expose session contents outside your Mac,
- any way to make it install an update that the release workflow here didn't sign, and
- problems with how the build scripts and workflows here create, sign or publish the app.

Vulnerabilities in the GitHub Copilot app itself should go to GitHub through
[its bug bounty program](https://bounty.github.com).

## Supported versions

Only the latest release, and the latest commit on `main`, are supported.

## How updates are verified

The app updates itself with [Sparkle](https://sparkle-project.org). It reads the appcast, a small
file that describes the latest release, from
`https://github.com/mnsn/copilot-pulse/releases/latest/download/appcast.xml`, and downloads the
update from the same release.

- The release workflow signs both the update's zip and the appcast with an EdDSA (Ed25519) key.
  The app has the public key in its `Info.plist` (`SUPublicEDKey`).
- The app rejects an appcast whose signature doesn't match (`SURequireSignedFeed`), with no
  fallback after a while (`SUSignedFeedFailureExpirationInterval` is 0). It checks the zip's
  signature before it even unpacks it (`SUVerifyUpdateBeforeExtraction`).
- The app is signed ad hoc and isn't notarized, so macOS code signing can't tie an update to this
  project. The EdDSA signature is the main protection.

The private key is kept only by the maintainer (in the Keychain of their Mac and in a password
manager) and in the `SPARKLE_PRIVATE_KEY` secret of the `release` environment in GitHub Actions.
Only the step that signs a release can read the secret, and the environment waits for a maintainer
to approve each release. Before publishing, the workflow checks the signatures against the public
key in `Info.plist`.

If the key were lost, users would have to download a new version by hand once, because the app
can't accept an update signed with a different key.

## Verifying a download

Releases are built and published by the
[release workflow](https://github.com/mnsn/copilot-pulse/blob/main/.github/workflows/release.yml)
from the tagged source, with a build provenance attestation. To check that a
`Copilot-Pulse.zip` you downloaded came from it, use the [GitHub CLI](https://cli.github.com):

```sh
gh attestation verify Copilot-Pulse.zip --repo mnsn/copilot-pulse
```

The release's `appcast.xml` has an attestation too. Each release also lists the zip's SHA-256,
which `shasum -a 256 Copilot-Pulse.zip` prints.

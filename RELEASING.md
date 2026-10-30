# Releasing Vibeshed

Public releases are tagged from `main`, built and notarized by the GitHub Actions [`Release`](.github/workflows/release.yml) workflow, and published as GitHub Releases. Homebrew users install via a separate tap that points at those release assets.

## One-time setup

### 1. Apple Developer signing certificate

You need a **Developer ID Application** certificate (not "Apple Development"). Export it from Keychain Access as a `.p12` with a password.

```sh
base64 -i DeveloperID.p12 -o DeveloperID.p12.base64
```

The signing identity string looks like `Developer ID Application: Your Name (TEAMID)`. Find it with:
```sh
security find-identity -v -p codesigning
```

### 2. App Store Connect API key (for notarization)

Create one at [appstoreconnect.apple.com](https://appstoreconnect.apple.com/access/integrations/api) → Users and Access → Integrations → Team Keys. Role: **Developer** is enough for notarization. Download the `.p8` (you only get to download it once).

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 -o NotaryKey.p8.base64
```

Record the **Key ID** (10 chars, on the same page) and **Issuer ID** (UUID at the top of the page).

### 3. GitHub repository secrets

Add these under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|--------|-------|
| `MACOS_CERT_P12_BASE64` | Contents of `DeveloperID.p12.base64` |
| `MACOS_CERT_PASSWORD` | Password used when exporting the `.p12` |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `MACOS_KEYCHAIN_PASSWORD` | Any random string — used for the temporary CI keychain |
| `MACOS_NOTARY_API_KEY_BASE64` | Contents of `NotaryKey.p8.base64` |
| `MACOS_NOTARY_API_KEY_ID` | Key ID from App Store Connect |
| `MACOS_NOTARY_API_KEY_ISSUER` | Issuer ID from App Store Connect |

### 4. Homebrew tap (optional but recommended)

Create a repo named `homebrew-tap` (literal prefix `homebrew-`) under your GitHub account, with a `Casks/vibeshed.rb` copied from the template at [`scripts/Casks/vibeshed.rb`](scripts/Casks/vibeshed.rb). `scripts/cut-release.sh` keeps it up to date.

Users then install with `brew install --cask idmitriev/tap/vibeshed`.

## Cutting a release

```sh
scripts/cut-release.sh 0.2.0
```

Needs an authenticated `gh` with write access to this repo and the tap, and nothing else: it works from any checkout, whatever state the working tree is in.

1. Waits for CI on `main` and stops if it's red.
2. Tags `origin/main` as `v0.2.0` and pushes the tag.
3. Waits for the Release workflow (~6 min): build → codesign → notarize → staple → GitHub Release → one commit on `main` updating the website, the cask template and `project.yml`.
4. Checks the cask's `sha256` against the release asset's digest and commits the cask to the tap's `main`.

If anything fails, fix it and rerun the same command. It resumes from where it stopped, and prints the `gh run rerun` command when the workflow is what failed. A rerun reads the current repository secrets, so a bad secret doesn't need a new tag.

## Versioning

Semver. Nothing needs a version bump before tagging: tagged builds take the version from the tag, and the workflow updates `project.yml` afterwards.

## Pre-release builds

Tags containing `-` (e.g. `v0.2.0-rc1`) are uploaded as **prereleases** automatically. The website and Homebrew stay on the last stable release.

## Manual / local release builds

`make build` produces a locally-signed `.build/Vibeshed.app` using your Apple Development cert — that's for testing, not distribution. To produce a Developer ID build locally, run the workflow's "Build and sign .app" step by hand with your `Developer ID Application` identity.

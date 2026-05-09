# Homebrew Cask Setup

Distribute Toru CLI through Homebrew so users avoid the Gatekeeper "couldn't verify" warning without paying for an Apple Developer ID.

Homebrew strips the quarantine attribute when installing casks, which is the legal, zero-cost equivalent of right-click → Open.

End result for users:

```bash
brew install --cask dimsmaul/toru/toru-cli
```

…and the app launches without any security prompt.

---

## One-time setup

Done once. After this, every release auto-publishes to the tap.

### 1. Create the tap repository

A Homebrew "tap" is just a GitHub repo whose name starts with `homebrew-`. Homebrew finds it via the convention `<owner>/<tap>` → `github.com/<owner>/homebrew-<tap>`.

1. On GitHub, create a new **public** repo named `homebrew-toru` under your `dimsmaul` account.
2. Initialize it with a README (anything will do).
3. The `Casks/toru-cli.rb` file gets written automatically by the release workflow — you don't need to add it manually.

After this, users will install via:

```bash
brew install --cask dimsmaul/toru/toru-cli
```

The `dimsmaul/toru` part is shorthand for `dimsmaul/homebrew-toru`.

### 2. Create a fine-grained Personal Access Token

The release workflow needs to push commits into `homebrew-toru`. The default `GITHUB_TOKEN` only has access to the current repo, so we need a separate token scoped to the tap.

1. GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**.
2. Name: `toru-homebrew-tap`.
3. Expiration: 1 year (or whatever fits your rotation policy).
4. Resource owner: your account (`dimsmaul`).
5. Repository access: **Only select repositories** → `dimsmaul/homebrew-toru`.
6. Permissions → Repository permissions:
   - **Contents**: Read and write
   - Everything else: leave at default (No access).
7. Generate → copy the token, you'll only see it once.

### 3. Add the token as a workflow secret

In the **Toru CLI** repo (this one):

1. **Settings → Secrets and variables → Actions → New repository secret**.
2. Name: `HOMEBREW_TAP_TOKEN`
3. Value: paste the token from step 2.

That's it. The next tag push will publish to the tap automatically.

---

## What the workflow does on each release

For every `v*` tag pushed to `dimsmaul/toru-cli`:

1. Build the `.app` and package it as a DMG (existing behavior).
2. Compute the DMG's SHA-256.
3. Clone `dimsmaul/homebrew-toru` using the PAT.
4. Generate a new `Casks/toru-cli.rb` with the version and SHA filled in.
5. Commit + push as `github-actions[bot]`.

The cask points back at the GitHub Release URL, so the DMG itself is still hosted on the main repo's Releases page — Homebrew only stores the metadata.

If `HOMEBREW_TAP_TOKEN` isn't set, the step logs a warning and exits cleanly. The rest of the release still publishes; you can wire the token up later.

---

## Cask layout reference

The generated `Casks/toru-cli.rb` looks like this (using `0.1.0` as an example):

```ruby
cask "toru-cli" do
  version "0.1.0"
  sha256 "abc…"

  url "https://github.com/dimsmaul/toru-cli/releases/download/v#{version}/Toru-CLI-v#{version}.dmg"
  name "Toru CLI"
  desc "Block-based macOS terminal"
  homepage "https://github.com/dimsmaul/toru-cli"

  app "Toru CLI.app"

  zap trash: [
    "~/Library/Application Support/Toru CLI",
    "~/Library/Preferences/com.torucli.Toru-CLI.plist",
    "~/Library/Saved Application State/com.torucli.Toru-CLI.savedState",
  ]
end
```

`zap` tells Homebrew which files to remove on `brew uninstall --zap toru-cli` — handy because Toru CLI writes a SQLite history database into `Application Support`.

---

## Testing locally before a real release

You can validate the cask without going through CI:

```bash
# Clone the tap
git clone https://github.com/dimsmaul/homebrew-toru ~/dev/homebrew-toru

# Hand-edit Casks/toru-cli.rb against an existing release
cd ~/dev/homebrew-toru

# Tap the local copy
brew tap-new dimsmaul/toru --no-git || true
brew tap dimsmaul/toru "$PWD"

# Install
brew install --cask dimsmaul/toru/toru-cli

# Check that quarantine was stripped
xattr -p com.apple.quarantine /Applications/Toru\ CLI.app
# (should print nothing)
```

`brew audit --cask Casks/toru-cli.rb` will catch most spec issues before you push.

---

## README install snippet

Add this to the project README so users see it first:

````markdown
## Install

```bash
brew install --cask dimsmaul/toru/toru-cli
```

If you don't have Homebrew, grab the latest DMG from
[Releases](https://github.com/dimsmaul/toru-cli/releases). On first launch
right-click the app → **Open** to bypass Gatekeeper (the build is
ad-hoc signed, not Apple-notarized).
````

---

## Future: drop right-click → Open entirely

Once you sign up for the Apple Developer Program ($99/year), the workflow can:

1. Sign with a real Developer ID certificate.
2. Submit to Apple notary service via `xcrun notarytool submit --wait`.
3. Staple the ticket onto the DMG via `xcrun stapler staple`.

Notarized DMGs install cleanly even outside Homebrew. Until then, the Cask path covers ~95% of users; the manual DMG download covers the rest.

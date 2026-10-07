---
name: macos-cli-install
description: Install CLI tools on macOS via brew or direct binary fetch.
---

# Installing CLI tools on macOS

Use this when the user asks to install a CLI tool (`brew install <x>`, or any
new binary). Covers both the happy path and the fallback when brew itself is
blocked by a setup problem (missing Command Line Tools, tap-trust, etc.).

## Step 1 — Try brew first

```bash
brew install <formula>
```

If the formula lives in a tap, tap it first:

```bash
brew tap <user>/<tap>
brew install <user>/<tap>/<formula>
```

## Step 2 — Read the formula when brew fails

Brew failures are often **setup state, not the tool**. Before debugging the
environment, check whether the formula is even doing real work:

```bash
cat "$(brew --prefix)/Library/Taps/<user>/homebrew-<tap>/Formula/<name>.rb"
```

Two things to look for:

- **Prebuilt binary formula** — the `url` points to a release `.tar.gz` /
  `.zip` and the `def install` body is just `bin.install "<name>"` (plus maybe
  completions). This means brew only *downloads and copies* a file; it compiles
  nothing.
- **Source-build formula** — no `url`, or `def install` invokes a build system
  (`make`, `cargo build`, `go build`, etc.). This genuinely needs a compiler
  toolchain.

## Step 3 — Fallback: install the prebuilt binary manually

When the formula is a prebuilt binary (most Go/Rust CLIs), you do not need brew
at all. The formula already tells you the exact URL and the expected SHA256 —
use them to download and verify directly:

```bash
# 1. Grab url + sha256 from the formula (pick the arch matching `uname -m`)
curl -sL "<url from formula>" -o /tmp/<name>.tar.gz

# 2. Verify checksum matches the formula's sha256
shasum -a 256 /tmp/<name>.tar.gz

# 3. Extract and install to ~/bin (already on PATH for this user)
tar xzf /tmp/<name>.tar.gz
mkdir -p ~/bin
cp <name> ~/bin/<name> && chmod +x ~/bin/<name>

# 4. Confirm
which <name> && <name> --version

# 5. Clean up
rm -f /tmp/<name>.tar.gz /tmp/<name>
```

The SHA256 check is the part that matters — it turns "downloaded some random
binary from the internet" into the exact same artifact brew would have
installed. Never skip it.

## Pitfalls

- **"Xcode alone is not sufficient on Sequoia"** — this brew error means
  Command Line Tools are missing (`xcode-select --install`) even though full
  Xcode is present. It blocks even *prebuilt* formulas (brew refuses to proceed
  on the `install` step). Do NOT fight this — go straight to Step 3's manual
  download; the formula's binary needs no toolchain.
- **`uname -m` matters** — Darwin release assets come in `arm64` and `x86_64`.
  Match the arch or the binary won't execute.
- **Tap-trust warnings** — newer brew warns about untrusted taps and can ignore
  their formulae. The manual-download fallback sidesteps this entirely.
- `~/bin` is already on PATH for this user, so manual installs are immediately
  usable. Confirm with `echo "$PATH" | grep "$HOME/bin"` rather than assuming.

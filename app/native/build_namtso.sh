#!/usr/bin/env bash
# Build the Namtso salt-harvest CLI from the flat submodule.
#
# great-wallet pins namtso-the-sacred-salt as a flat submodule (ARCHITECTURE.md
# §"Submodule Rules" — only great-wallet has submodules, and they are flat: the
# orbit protocol's root o_0 = H(sigma) consumes a Namtso salt, but the core
# engine stays decoupled and only accepts a pre-harvested sigma, so Namtso lives
# beside great-wall-core, not nested inside it).
#
# This builds Namtso's CLI, which the app uses to harvest sigma on desktop:
#
#   namtso harvest --date YYYY-MM-DD [--node <rpc> | --explorer <urls> | --headers <file>]
#       -> stdout: sigma (hex) + receipt JSON
#
# Output binary:
#   namtso-the-sacred-salt/target/release/namtso
#
# Usage:  app/native/build_namtso.sh   (run from anywhere)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# app/native -> app -> great-wallet
repo_root="$(cd "$here/../.." && pwd)"
namtso_dir="$repo_root/namtso-the-sacred-salt"

if [ ! -f "$namtso_dir/Cargo.toml" ]; then
  echo "error: namtso submodule not initialised at:" >&2
  echo "  $namtso_dir" >&2
  echo "run: git submodule update --init namtso-the-sacred-salt" >&2
  exit 1
fi

# Default features include `cli` (which pulls the network header sources the CLI
# drives). An air-gapped build that only ever uses --headers can pass
# NAMTSO_OFFLINE=1 to drop ureq/clap... except the CLI itself needs clap, so the
# CLI always builds with default features; the *engine* is what consumes the
# pure core (great-wall-core does not depend on Namtso at all).
echo "Building namtso CLI (release) in $namtso_dir ..."
cargo build --release --manifest-path "$namtso_dir/Cargo.toml" --bin namtso
echo "Done. Binary at: $namtso_dir/target/release/namtso"
ls -1 "$namtso_dir/target/release/" | grep -E '^namtso$' || true

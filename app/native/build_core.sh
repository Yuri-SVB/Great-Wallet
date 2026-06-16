#!/usr/bin/env bash
# Build the great-wall-core engine as a shared library for the app's FFI layer.
#
# great-wallet pins great-wall-core as a flat submodule (ARCHITECTURE.md
# §"Submodule Rules"). This builds its Rust cdylib into the location the
# app's CoreLibraryLoader probes by default:
#
#   great-wall-core/burning_ship/rust_engine/target/release/
#       lib burning_ship_engine .{so,dylib}  |  burning_ship_engine.dll
#
# Usage:  app/native/build_core.sh   (run from anywhere)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# app/native -> app -> great-wallet
repo_root="$(cd "$here/../.." && pwd)"
engine_dir="$repo_root/great-wall-core/burning_ship/rust_engine"

if [ ! -f "$engine_dir/Cargo.toml" ]; then
  echo "error: great-wall-core submodule not initialised at:" >&2
  echo "  $engine_dir" >&2
  echo "run: git submodule update --init great-wall-core" >&2
  exit 1
fi

echo "Building burning_ship_engine (release) in $engine_dir ..."
cargo build --release --manifest-path "$engine_dir/Cargo.toml"
echo "Done. Library at: $engine_dir/target/release/"
ls -1 "$engine_dir/target/release/" | grep -E 'burning_ship_engine' || true

#!/usr/bin/env bash
# Actual Swift -> C ABI -> Rust -> synthetic pairing peer. LOOPBACK ONLY.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p .build/ncm-tests
clang -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
 ncm-dev/fixtures/pairing_peer.c -o .build/ncm-tests/pairing_peer
# Separate target directory ensures test-only exports cannot enter iOS artifacts.
NCM_RUST_TARGET_DIR="$root/.build/ncm-rust-fixtures" bash tools/with_ncm_rust.sh cargo build --offline --locked --manifest-path ncm-dev/rust/Cargo.toml --features offline-fixtures --release --target aarch64-apple-darwin
export NCM_OFFLINE_FIXTURES=1
export NCM_BACKEND_ARCHIVE_DIR="$root/.build/ncm-rust-fixtures/aarch64-apple-darwin/release"
export NCM_PAIRING_FIXTURE="$root/.build/ncm-tests/pairing_peer"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$root/.build/ncm-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/ncm-module-cache"
swift test --disable-sandbox --package-path "$root/ncm-dev/TapitoNCM" \
 --scratch-path "$root/.build/ncm-swift-chain" --cache-path "$root/.build/swift-cache"

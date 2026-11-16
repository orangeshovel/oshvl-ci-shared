#!/usr/bin/env bash
# Install a pinned, checksum-verified betterleaks binary and add it to $GITHUB_PATH.
# Downloaded fresh on every run into a per-run temp dir (never a shared cache), so a
# partial download or a binary replaced by another job on a shared self-hosted runner can
# never be used: the tarball is verified against an embedded SHA-256 each time.
set -euo pipefail

VERSION=1.10.1
case "$(uname -m)" in
  x86_64)        ARCH=x64;   SHA256=c174b42d7aa60caf58c0c3e555c0e4bed01fe6b0d99a412bce777b5af4ce913e ;;
  aarch64|arm64) ARCH=arm64; SHA256=62a63199f9f61a6b5e5a6f58f048493db20fbc8c770014f4d903a4d97886e1bf ;;
  *) echo "::error::unsupported architecture $(uname -m)"; exit 1 ;;
esac

DEST="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/betterleaks.XXXXXX")"
# Redirect stdout instead of `curl -o` (snap-packaged curl can't write arbitrary paths).
curl -fsSL --proto '=https' --retry 3 --retry-delay 2 \
  "https://github.com/betterleaks/betterleaks/releases/download/v${VERSION}/betterleaks_${VERSION}_linux_${ARCH}.tar.gz" \
  > "$DEST/betterleaks.tar.gz"
echo "${SHA256}  $DEST/betterleaks.tar.gz" | sha256sum -c -
tar -xzf "$DEST/betterleaks.tar.gz" -C "$DEST" betterleaks
rm -f "$DEST/betterleaks.tar.gz"
echo "$DEST" >> "${GITHUB_PATH:?GITHUB_PATH must be set}"

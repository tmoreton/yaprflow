#!/usr/bin/env bash

set -euo pipefail

cat >&2 <<'EOF'
error: scripts/create-release-dmg.sh is retired because it bypassed the
       repository's release verification. Use scripts/release.sh for a local
       Developer ID DMG, or scripts/app-store-release.sh for a commercial
       Mac App Store archive and package.
EOF
exit 2

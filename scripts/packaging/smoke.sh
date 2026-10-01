#!/usr/bin/env bash
# 2GP packaging smoke test. Needs a Dev Hub, a namespace, and a scratch org.
# Usage: scripts/packaging/smoke.sh <devhub-alias> <scratch-alias> <namespace>
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <devhub-alias> <scratch-alias> <namespace>" >&2
  exit 2
fi
HUB=$1
ORG=$2
NS=$3
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
# A beta version of the package in force-app. The package needs the namespace.
sf package version create --package revenant --target-dev-hub "$HUB" \
  --installation-key-bypass --wait 60 --json > "$WORK/version.json"
VERSION_ID=$(node -p "require('$WORK/version.json').result.SubscriberPackageVersionId")

sf package install --package "$VERSION_ID" --target-org "$ORG" \
  --wait 30 --no-prompt

# Subscriber source: the token __NS__ becomes the package namespace.
mkdir -p "$WORK/src/classes"
for f in scripts/packaging/subscriber/*; do
  sed "s/__NS__/$NS/g" "$f" > "$WORK/src/classes/$(basename "$f")"
done
sf project deploy start --source-dir "$WORK/src" --target-org "$ORG" --wait 10

echo "System.debug(SmokeRun.run());" > "$WORK/run.apex"
sf apex run --file "$WORK/run.apex" --target-org "$ORG"

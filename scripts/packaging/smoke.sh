#!/usr/bin/env bash
# 2GP packaging smoke test. Needs a Dev Hub, a linked namespace and a scratch org.
# Usage: scripts/packaging/smoke.sh <devhub> <scratch-org> <namespace> <package-id>
# <package-id> is the 0Ho Id from `sf package create`.
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <devhub> <scratch-org> <namespace> <package-id>" >&2
  exit 2
fi
HUB=$1
ORG=$2
NS=$3
PKG=$4
if [[ ! $NS =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
  echo "Bad namespace: $NS" >&2
  exit 2
fi
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Package project: only force-app, with the namespace.
mkdir -p "$WORK/pkg"
cp -R "$ROOT/force-app" "$WORK/pkg/force-app"
cat > "$WORK/pkg/sfdx-project.json" <<JSON
{
  "packageDirectories": [
    {
      "path": "force-app",
      "default": true,
      "package": "revenant",
      "versionName": "Smoke",
      "versionNumber": "0.0.0.NEXT"
    }
  ],
  "namespace": "$NS",
  "sourceApiVersion": "67.0",
  "packageAliases": { "revenant": "$PKG" }
}
JSON

# Create a beta version and install it.
(cd "$WORK/pkg" && sf package version create --package revenant \
  --target-dev-hub "$HUB" --installation-key-bypass --wait 60 \
  --json > "$WORK/version.json")
VERSION_ID=$(node -p "process.argv[1] && require(process.argv[1]).result.SubscriberPackageVersionId" "$WORK/version.json")
if [[ ! $VERSION_ID == 04t* ]]; then
  echo "Package version was not created. See $WORK/version.json" >&2
  trap - EXIT
  exit 1
fi
sf package install --package "$VERSION_ID" --target-org "$ORG" \
  --wait 30 --no-prompt

# Subscriber project: the token __NS__ becomes the package namespace.
mkdir -p "$WORK/sub/force-app/main/default/classes"
for f in "$ROOT"/scripts/packaging/subscriber/*; do
  sed "s/__NS__/$NS/g" "$f" > "$WORK/sub/force-app/main/default/classes/$(basename "$f")"
done
cat > "$WORK/sub/sfdx-project.json" <<'JSON'
{
  "packageDirectories": [{ "path": "force-app", "default": true }],
  "namespace": "",
  "sourceApiVersion": "67.0"
}
JSON
(cd "$WORK/sub" && sf project deploy start --target-org "$ORG" --wait 10)

# SmokeRun throws when a call fails. The exit code shows the result.
echo "System.debug(SmokeRun.run());" > "$WORK/run.apex"
sf apex run --file "$WORK/run.apex" --target-org "$ORG"

#!/usr/bin/env bash
# Downloads apex-ls and its dependencies to scripts/global-api/.apex-ls/lib.
# The global-api test uses it for the packaged-view compile. Needs Java and Maven.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)/.apex-ls"
VERSION="${APEX_LS_VERSION:-6.2.0}"
mkdir -p "$DIR"
cat >"$DIR/pom.xml" <<EOF
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>local</groupId>
  <artifactId>apex-ls-fetch</artifactId>
  <version>1</version>
  <dependencies>
    <dependency>
      <groupId>io.github.apex-dev-tools</groupId>
      <artifactId>apex-ls_2.13</artifactId>
      <version>${VERSION}</version>
    </dependency>
  </dependencies>
</project>
EOF
mvn -q -f "$DIR/pom.xml" dependency:copy-dependencies -DoutputDirectory="$DIR/lib"
echo "apex-ls ${VERSION} is in $DIR/lib"

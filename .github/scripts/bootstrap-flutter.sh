#!/usr/bin/env bash
set -euo pipefail

readonly flutter_version='3.50.1'
readonly flutter_commit='ae9b586f34a8443573f82ef57c3bf914a908cbf7'
readonly flutter_directory="${RUNNER_TEMP:?}/flutter-${flutter_version}"

git clone --depth 1 --branch "$flutter_version" \
  https://github.com/flutter/flutter.git "$flutter_directory"
actual_commit=$(git -C "$flutter_directory" rev-parse HEAD)
if [[ "$actual_commit" != "$flutter_commit" ]]; then
  printf 'Unexpected Flutter revision for %s\n' "$flutter_version" >&2
  exit 1
fi

# Initialize the fresh checkout before reading the machine-readable version.
"$flutter_directory/bin/flutter" --version
"$flutter_directory/bin/flutter" --version --machine | python3 -c '
import json
import sys

version = json.load(sys.stdin)
if version["frameworkVersion"] != sys.argv[1] or version["frameworkRevision"] != sys.argv[2]:
    sys.exit("The pinned Flutter tool reported a different version or revision.")
print("Flutter {}, Dart {}".format(version["frameworkVersion"], version["dartSdkVersion"]))
' "$flutter_version" "$flutter_commit"

printf '%s\n' "$flutter_directory/bin" >> "${GITHUB_PATH:?}"

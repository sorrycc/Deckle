#!/usr/bin/env bash
# Sets a new version in Cargo.toml and Cargo.lock, commits it as v<version>
# with a tag of the same name, and after asking pushes main and the tag, which
# makes the Release workflow build and publish it.
# Usage: scripts/bump.sh <version | keyword>
#
# The argument is a version, such as 0.2.0 or 0.2.0-beta.1, or a keyword that
# works it out from the current one, as npm version does:
#   patch, minor, major        the next release, or the current one without its
#                              pre-release part when that is the same thing
#                              (0.1.0-beta.1 patch -> 0.1.0, 0.1.0 patch -> 0.1.1)
#   beta                       the next beta (0.1.0-beta.1 -> 0.1.0-beta.2,
#                              0.1.0 -> 0.1.1-beta.1)
#   prepatch, preminor, premajor   the first beta of the next patch, minor or major
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ $# -ne 1 ]; then
    sed -n '2,15s/^# \{0,1\}//p' "$0" >&2
    exit 1
fi

CURRENT="$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"$/\1/p' "$ROOT/Cargo.toml")"
# Prints the new version, or fails when the argument isn't a version or keyword
# or doesn't come after the current version.
VERSION="$(/usr/bin/python3 - "$CURRENT" "$1" <<'EOF'
import re, sys

SEMVER = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")

def parse(v):
    m = SEMVER.fullmatch(v)
    if not m:
        sys.exit(f"{v} isn't a version such as 1.2.0 or 1.2.0-beta.1.")
    return int(m[1]), int(m[2]), int(m[3]), m[4]

def key(v):
    # Semver precedence: a pre-release comes before its release, numeric
    # identifiers compare as numbers and before alphanumeric ones.
    major, minor, patch, pre = parse(v)
    ids = [(0, int(i), "") if i.isdigit() else (1, 0, i) for i in pre.split(".")] if pre else []
    return (major, minor, patch, pre is None, ids)

current, arg = sys.argv[1], sys.argv[2]
major, minor, patch, pre = parse(current)
if arg == "patch":
    new = (major, minor, patch if pre else patch + 1, None)
elif arg == "minor":
    new = (major, minor, 0, None) if pre and patch == 0 else (major, minor + 1, 0, None)
elif arg == "major":
    new = (major, 0, 0, None) if pre and minor == patch == 0 else (major + 1, 0, 0, None)
elif arg == "beta":
    m = re.fullmatch(r"beta\.(\d+)", pre or "")
    if m:
        new = (major, minor, patch, f"beta.{int(m[1]) + 1}")
    else:
        new = (major, minor, patch if pre else patch + 1, "beta.1")
elif arg == "prepatch":
    new = (major, minor, patch + 1, "beta.1")
elif arg == "preminor":
    new = (major, minor + 1, 0, "beta.1")
elif arg == "premajor":
    new = (major + 1, 0, 0, "beta.1")
else:
    new = parse(arg)
version = "%d.%d.%d" % new[:3] + (f"-{new[3]}" if new[3] else "")
if key(version) <= key(current):
    sys.exit(f"{version} doesn't come after the current version {current}.")
print(version)
EOF
)"
TAG="v$VERSION"

cd "$ROOT"
if [ "$(git symbolic-ref --short HEAD 2>/dev/null)" != main ]; then
    echo "Releases are made from main. Switch to it first." >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "The working tree has changes. Commit them first." >&2
    exit 1
fi
git fetch --quiet --tags origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "main differs from origin/main. Pull or push first." >&2
    exit 1
fi
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null \
    || [ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ]; then
    echo "Tag $TAG exists already." >&2
    exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG exists already." >&2
    exit 1
fi

echo "==> $CURRENT -> $VERSION"
sed -i '' "/^\[workspace.package\]/,/^\[/s/^version = \".*\"$/version = \"$VERSION\"/" Cargo.toml
# Updates only the workspace's own crates in the lock file.
cargo update --quiet --workspace
if [ "$(git diff --name-only)" != "$(printf 'Cargo.lock\nCargo.toml')" ] \
    || git diff -U0 Cargo.lock | grep '^[-+][^-+]' | grep -qv '^[-+]version = '; then
    echo "Expected only the versions in Cargo.toml and Cargo.lock to change:" >&2
    git diff --stat >&2
    echo "Undo with: git checkout -- ." >&2
    exit 1
fi
git commit --quiet -m "$TAG" Cargo.toml Cargo.lock
git tag "$TAG"
git --no-pager log -1 --stat --format='%h %s' "$TAG"

read -r -p "Push main and $TAG to origin, which publishes the release? [y/N] " answer || echo
if [[ "$answer" != [yY]* ]]; then
    echo "Not pushed. Push later with: git push origin main $TAG"
    echo "Or undo with: git tag -d $TAG && git reset --hard HEAD~1"
    exit 0
fi
git push --quiet --atomic origin main "$TAG"
echo "==> pushed $TAG. The Release workflow: https://github.com/sorrycc/Deckle/actions/workflows/release.yml"

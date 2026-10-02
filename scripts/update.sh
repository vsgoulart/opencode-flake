#!/usr/bin/env bash
# Pins the newest upstream OpenCode v1 and v2 artifacts in sources.json.
#
# Only release metadata is downloaded: upstream publishes a SHA-256 digest for
# every artifact (GitHub release asset digests for v1, the opencode.ai update
# manifest for v2), so nothing large has to be fetched to compute hashes.
#
# Writes changed_v1, changed_v2, v1_version and v2_version to $GITHUB_OUTPUT
# when running in GitHub Actions.
set -euo pipefail

sources=sources.json
repo=anomalyco/opencode
manifest_url=https://opencode.ai/update/api/latest

[[ -f flake.nix ]] || { echo "Run from the repository root." >&2; exit 1; }
[[ -f "$sources" ]] || echo '{}' >"$sources"

# Nix system -> upstream artifact name, per package.
declare -A cli_assets=(
  [x86_64-linux]=opencode-linux-x64.tar.gz
  [aarch64-darwin]=opencode-darwin-arm64.zip
)
declare -A desktop_assets=(
  [x86_64-linux]=opencode-desktop-linux-amd64.deb
  [aarch64-darwin]=opencode-desktop-mac-arm64.app.tar.gz
)

sri() {
  nix --extra-experimental-features nix-command hash convert --hash-algo sha256 --to sri "$1"
}

# Prints 0 when $1 is newer than $2 (or $2 is empty).
is_newer() {
  [[ -z "$2" || ( "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ) ]]
}

# Builds a package entry from a JSON object { "<asset name>": { url, sha256hex } }.
package_json() {
  local version="$1" files="$2" kind="$3"
  local -n assets="${kind}_assets"
  local entry
  entry="$(jq -n --arg v "$version" '{version: $v}')"
  for system in "${!assets[@]}"; do
    local name="${assets[$system]}" url hex
    url="$(jq -r --arg n "$name" '.[$n].url // empty' <<<"$files")"
    hex="$(jq -r --arg n "$name" '.[$n].sha256 // empty' <<<"$files")"
    if [[ -z "$url" ]]; then
      echo "Missing artifact $name for $kind $version." >&2
      return 1
    fi
    if [[ -z "$hex" ]]; then
      echo "No published digest for $name; prefetching." >&2
      hash="$(nix --extra-experimental-features nix-command store prefetch-file --json "$url" | jq -r .hash)"
    else
      hash="$(sri "$hex")"
    fi
    entry="$(jq --arg s "$system" --arg u "$url" --arg h "$hash" '.[$s] = {url: $u, hash: $h}' <<<"$entry")"
  done
  jq -S . <<<"$entry"
}

# --- v1: GitHub releases ------------------------------------------------------
# Picks the highest stable v1.x.y release that already has every needed asset
# with a digest (assets are uploaded after the release is created).
v1_release="$(
  gh api "repos/$repo/releases?per_page=100" | jq -c '
    [ .[]
      | select(.draft | not)
      | select(.prerelease | not)
      | select(.tag_name | test("^v1\\.[0-9]+\\.[0-9]+$"))
    ]'
)"
v1_version=""
v1_files=""
needed="$(printf '%s\n' "${cli_assets[@]}" "${desktop_assets[@]}" | jq -R . | jq -sc .)"
for tag in $(jq -r '.[].tag_name' <<<"$v1_release" | sort -Vr); do
  files="$(jq -c --arg t "$tag" '
    .[] | select(.tag_name == $t) | .assets
    | map({ key: .name,
            value: { url: .browser_download_url,
                     sha256: ((.digest // "") | ltrimstr("sha256:")) } })
    | from_entries' <<<"$v1_release")"
  if jq -e --argjson n "$needed" '. as $f | all($n[]; $f[.] != null)' <<<"$files" >/dev/null; then
    v1_version="${tag#v}"
    v1_files="$files"
    break
  fi
  echo "Skipping $tag: assets not fully published yet." >&2
done
[[ -n "$v1_version" ]] || { echo "No complete v1 release found." >&2; exit 1; }

# --- v2: opencode.ai update manifest -------------------------------------------
manifest="$(curl -fsSL --retry 3 "$manifest_url")"
v2_artifact() {
  jq -c --arg n "$1" '
    [.artifacts[] | select(.name == $n and .distribution == "opencode")][0]
    | { version, files: (.metadata.files | map_values({url, sha256})) }' <<<"$manifest"
}
v2_cli="$(v2_artifact cli)"
v2_desktop="$(v2_artifact desktop)"

# --- Assemble --------------------------------------------------------------------
current="$(cat "$sources")"
new="$current"
changed_v1=false
changed_v2=false

update_package() {
  local track="$1" kind="$2" version="$3" files="$4"
  local major="${track#v}" old
  if [[ "$version" != "$major."* ]]; then
    echo "Upstream $kind $version does not belong to track $track; refusing to update." >&2
    return 1
  fi
  old="$(jq -r --arg t "$track" --arg k "$kind" '.[$t][$k].version // ""' <<<"$current")"
  if ! is_newer "$version" "$old"; then
    [[ "$version" == "$old" ]] || echo "Ignoring $track $kind $version: older than pinned $old." >&2
    return 0
  fi
  echo "$track $kind: ${old:-none} -> $version"
  local entry
  entry="$(package_json "$version" "$files" "$kind")"
  new="$(jq -S --arg t "$track" --arg k "$kind" --argjson e "$entry" '.[$t][$k] = $e' <<<"$new")"
  printf -v "changed_${track}" true
}

update_package v1 cli "$v1_version" "$v1_files"
update_package v1 desktop "$v1_version" "$v1_files"
update_package v2 cli "$(jq -r .version <<<"$v2_cli")" "$(jq -c .files <<<"$v2_cli")"
update_package v2 desktop "$(jq -r .version <<<"$v2_desktop")" "$(jq -c .files <<<"$v2_desktop")"

jq -S . <<<"$new" >"$sources"

v1_pinned="$(jq -r '.v1.cli.version' "$sources")"
v2_pinned="$(jq -r '.v2.cli.version' "$sources")"
echo "Pinned v1 $v1_pinned (changed: $changed_v1), v2 $v2_pinned (changed: $changed_v2)."

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "changed_v1=$changed_v1"
    echo "changed_v2=$changed_v2"
    echo "v1_version=$v1_pinned"
    echo "v2_version=$v2_pinned"
  } >>"$GITHUB_OUTPUT"
fi

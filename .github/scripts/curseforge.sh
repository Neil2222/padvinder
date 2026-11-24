#!/usr/bin/env bash
# Upload a release zip to CurseForge.
#   curseforge.sh check                      - only look up the game version (no upload)
#   curseforge.sh upload <zip> <tag> <notes> - upload <zip> as "Padvinder <tag>", changelog from file <notes>
# Needs CF_API_KEY. The game version comes from "## Interface:" in Padvinder.toc
# (16001 -> 1.60.1) and is looked up among CurseForge's WoW Forever versions.
set -euo pipefail

PROJECT_ID=1826474
API=https://wow.curseforge.com/api
: "${CF_API_KEY:?CF_API_KEY is not set}"

iface=$(grep -oP '^## Interface:\s*\K[0-9]+' Padvinder.toc)
version="$((iface / 10000)).$(((iface % 10000) / 100)).$((iface % 100))"

types=$(curl -sfS -H "X-Api-Token: $CF_API_KEY" "$API/game/version-types")
versions=$(curl -sfS -H "X-Api-Token: $CF_API_KEY" "$API/game/versions")

# The version types whose name mentions Forever, then the version with our number in one of them.
forever_types=$(jq -c '[.[] | select((.name + " " + .slug) | test("forever"; "i")) | .id]' <<<"$types")
echo "Forever version types: $(jq -c --argjson t "$forever_types" '[.[] | select(.id as $i | $t | index($i)) | {id, name, slug}]' <<<"$types")"
version_id=$(jq --arg v "$version" --argjson t "$forever_types" \
    '[.[] | select(.name == $v and (.gameVersionTypeID as $i | $t | index($i)))][0].id // empty' <<<"$versions")

if [ -z "$version_id" ]; then
    echo "::error::No WoW Forever game version $version on CurseForge (from Interface $iface)."
    echo "Versions called $version:"
    jq -c --arg v "$version" '[.[] | select(.name == $v)]' <<<"$versions"
    exit 1
fi
echo "Game version $version (Interface $iface) = CurseForge id $version_id"

[ "${1:-}" = "upload" ] || exit 0

zip=$2 tag=$3 notes=$4
metadata=$(jq -n --arg name "Padvinder $tag" --rawfile log "$notes" --argjson gv "$version_id" \
    '{displayName: $name, changelog: $log, changelogType: "markdown", gameVersions: [$gv], releaseType: "release"}')
curl -sfS -H "X-Api-Token: $CF_API_KEY" \
    --form-string "metadata=$metadata" -F "file=@$zip" \
    "$API/projects/$PROJECT_ID/upload-file"
echo
echo "Uploaded $zip to CurseForge."

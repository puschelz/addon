#!/usr/bin/env bash

set -euo pipefail

if [[ -z "${CURSEFORGE_API_KEY:-}" ]]; then
  echo "CURSEFORGE_API_KEY is required" >&2
  exit 1
fi

project_id="${CURSEFORGE_PROJECT_ID:-1492984}"
api_base="${CURSEFORGE_API_BASE:-https://wow.curseforge.com/api}"
tag_name="${CURSEFORGE_TAG_NAME:-${GITHUB_REF_NAME:-}}"
release_type="${CURSEFORGE_RELEASE_TYPE:-release}"
toc_path="${CURSEFORGE_TOC_PATH:-Puschelz/Puschelz.toc}"

if [[ -z "${tag_name}" ]]; then
  echo "CURSEFORGE_TAG_NAME or GITHUB_REF_NAME is required" >&2
  exit 1
fi

zip_path="${CURSEFORGE_FILE_PATH:-Puschelz-${tag_name}.zip}"
if [[ ! -f "${zip_path}" ]]; then
  echo "Release zip not found: ${zip_path}" >&2
  exit 1
fi

if [[ ! -f "${toc_path}" ]]; then
  echo "TOC not found: ${toc_path}" >&2
  exit 1
fi

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

interface_to_version() {
  local raw_build
  raw_build="$(trim "$1")"
  raw_build="${raw_build//[^0-9]/}"
  if [[ -z "${raw_build}" ]]; then
    echo "Empty interface build number" >&2
    return 1
  fi

  local build_number
  build_number=$((10#${raw_build}))
  local major minor patch
  major=$((build_number / 10000))
  minor=$(((build_number % 10000) / 100))
  patch=$((build_number % 100))
  printf '%d.%d.%d' "${major}" "${minor}" "${patch}"
}

declare -a version_names=()
declare -A seen_versions=()

if [[ -n "${CURSEFORGE_GAME_VERSIONS:-}" ]]; then
  IFS=',' read -r -a raw_versions <<< "${CURSEFORGE_GAME_VERSIONS}"
  for raw_version in "${raw_versions[@]}"; do
    version_name="$(trim "${raw_version}")"
    if [[ -n "${version_name}" && -z "${seen_versions[${version_name}]:-}" ]]; then
      seen_versions["${version_name}"]=1
      version_names+=("${version_name}")
    fi
  done
else
  interface_line="$(grep -E '^## Interface:' "${toc_path}" | head -n 1 | sed -E 's/^## Interface:[[:space:]]*//')"
  if [[ -z "${interface_line}" ]]; then
    echo "Could not read ## Interface from ${toc_path}" >&2
    exit 1
  fi

  IFS=',' read -r -a interface_builds <<< "${interface_line}"
  for raw_build in "${interface_builds[@]}"; do
    version_name="$(interface_to_version "${raw_build}")"
    if [[ -n "${version_name}" && -z "${seen_versions[${version_name}]:-}" ]]; then
      seen_versions["${version_name}"]=1
      version_names+=("${version_name}")
    fi
  done
fi

if [[ ${#version_names[@]} -eq 0 ]]; then
  echo "No CurseForge game versions were resolved" >&2
  exit 1
fi

echo "Resolving CurseForge game version ids for: ${version_names[*]}"
versions_json="$(curl --silent --show-error --fail-with-body \
  -H "X-Api-Token: ${CURSEFORGE_API_KEY}" \
  "${api_base}/game/versions")"

declare -a version_ids=()
for version_name in "${version_names[@]}"; do
  version_id="$(
    VERSIONS_JSON="${versions_json}" VERSION_NAME="${version_name}" python3 - <<'PY'
import json
import os

versions = json.loads(os.environ["VERSIONS_JSON"])
name = os.environ["VERSION_NAME"]

for version in versions:
    if version.get("name") == name:
        print(version["id"])
        break
PY
  )"

  if [[ -z "${version_id}" ]]; then
    echo "Could not find a CurseForge game version id for ${version_name}" >&2
    exit 1
  fi

  version_ids+=("${version_id}")
done

release_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-puschelz/puschelz-addon}/releases/tag/${tag_name}"
display_name="Puschelz ${tag_name}"
changelog=$(
  cat <<EOF
Automated release for \`${tag_name}\`.

GitHub release: ${release_url}
EOF
)

metadata_file="$(mktemp)"
trap 'rm -f "${metadata_file}"' EXIT

VERSION_IDS="$(IFS=,; printf '%s' "${version_ids[*]}")" \
CHANGELOG="${changelog}" \
DISPLAY_NAME="${display_name}" \
RELEASE_TYPE="${release_type}" \
METADATA_FILE="${metadata_file}" \
python3 - <<'PY'
import json
import os

version_ids = [int(value) for value in os.environ["VERSION_IDS"].split(",") if value]
metadata = {
    "changelog": os.environ["CHANGELOG"],
    "changelogType": "markdown",
    "displayName": os.environ["DISPLAY_NAME"],
    "gameVersions": version_ids,
    "releaseType": os.environ["RELEASE_TYPE"],
}

with open(os.environ["METADATA_FILE"], "w", encoding="utf-8") as handle:
    json.dump(metadata, handle)
PY

echo "Uploading ${zip_path} to CurseForge project ${project_id}"
curl --silent --show-error --fail-with-body \
  -H "X-Api-Token: ${CURSEFORGE_API_KEY}" \
  -F "metadata=<${metadata_file};type=application/json" \
  -F "file=@${zip_path}" \
  "${api_base}/projects/${project_id}/upload-file"

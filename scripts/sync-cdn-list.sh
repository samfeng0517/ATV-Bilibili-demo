#!/usr/bin/env bash

set -euo pipefail

readonly upstream_cdn_url="${CDN_LIST_UPSTREAM_URL:-https://raw.githubusercontent.com/a0972199950/bilibili-cdn-switcher/master/src/cdn-list.json}"
readonly upstream_messages_url="${CDN_MESSAGES_UPSTREAM_URL:-https://raw.githubusercontent.com/a0972199950/bilibili-cdn-switcher/master/src/_locales/zh_TW/messages.json}"

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/.." && pwd)"
cdn_sync_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cdn-list-sync.XXXXXX")"

cleanup() {
  if [[ -n "${cdn_sync_tmp_dir:-}" && -d "${cdn_sync_tmp_dir}" ]]; then
    rm -rf -- "${cdn_sync_tmp_dir}"
  fi
}
trap cleanup EXIT

upstream_cdn_file="${cdn_sync_tmp_dir}/cdn-list.json"
upstream_messages_file="${cdn_sync_tmp_dir}/messages.json"
generated_cdn_file="${cdn_sync_tmp_dir}/generated-cdn-list.json"
destination_file="${repository_root}/cdn-list.json"

curl --fail --silent --show-error --location \
  --retry 3 --connect-timeout 10 --max-time 60 \
  "${upstream_cdn_url}" --output "${upstream_cdn_file}"
curl --fail --silent --show-error --location \
  --retry 3 --connect-timeout 10 --max-time 60 \
  "${upstream_messages_url}" --output "${upstream_messages_file}"

jq -e 'type == "object" and (.options | type == "array")' \
  "${upstream_cdn_file}" >/dev/null
jq -e 'type == "object"' "${upstream_messages_file}" >/dev/null

jq --slurpfile translations "${upstream_messages_file}" '
  def trimmed:
    gsub("^\\s+|\\s+$"; "");

  def normalize_host:
    trimmed | ascii_downcase | sub("\\.$"; "");

  def valid_host:
    length <= 253
    and test("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$");

  def translated_message($catalog; $key):
    ($key // "") as $resolved_key
    | ($catalog[$resolved_key].message? // "") as $message
    | if (($message | type) == "string" and (($message | trimmed | length) > 0))
      then ($message | trimmed)
      else empty
      end;

  def fallback_name:
    ((.name? // "") | trimmed) as $technical_name
    | if $technical_name == "" then .value else $technical_name end;

  def display_name($catalog):
    translated_message($catalog; .noteKey?)
    // translated_message($catalog; .nameKey?)
    // fallback_name;

  [
    .options[]
    | select((.value? | type) == "string")
    | .value |= normalize_host
    | select(.value != "base" and .value != "backup")
    | select(.value | valid_host)
  ] as $candidates
  | reduce $candidates[] as $option (
      {seen: {}, nodes: []};
      if .seen[$option.value]
      then .
      else .seen[$option.value] = true
        | .nodes += [{
            name: ($option | display_name($translations[0])),
            host: $option.value
          }]
      end
    )
  | {version: 1, nodes: .nodes}
' "${upstream_cdn_file}" >"${generated_cdn_file}"

jq -e '
  .version == 1
  and (.nodes | type == "array")
  and ((.nodes | length) > 0)
  and all(.nodes[]; (.name | type == "string") and (.name | length > 0))
  and all(.nodes[]; (.host | type == "string") and (.host | length > 0))
  and (([.nodes[].host | ascii_downcase] | length) == ([.nodes[].host | ascii_downcase] | unique | length))
' "${generated_cdn_file}" >/dev/null

upstream_node_count="$(jq '[.options[] | select((.value? | type) == "string") | select(.value != "base" and .value != "backup")] | length' "${upstream_cdn_file}")"
generated_node_count="$(jq '.nodes | length' "${generated_cdn_file}")"
skipped_node_count="$((upstream_node_count - generated_node_count))"

if cmp -s "${generated_cdn_file}" "${destination_file}"; then
  echo "CDN 清單沒有變更（${generated_node_count} 個唯一節點；略過 ${skipped_node_count} 個重複或無效節點）。"
  exit 0
fi

mv -- "${generated_cdn_file}" "${destination_file}"
echo "已同步 ${generated_node_count} 個唯一 CDN 節點；略過 ${skipped_node_count} 個重複或無效節點。"

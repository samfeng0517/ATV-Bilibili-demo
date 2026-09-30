#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/.." && pwd)"
cdn_check_directory="$(mktemp -d /tmp/cdn-startup-check.XXXXXX)"
trap 'rm -rf -- "${cdn_check_directory}"' EXIT

xcrun swiftc -parse-as-library \
  -module-cache-path "${cdn_check_directory}/module-cache" \
  "${repository_root}/BilibiliLive/Component/Player/CDNStartupSelection.swift" \
  "${script_directory}/check-cdn-startup.swift" \
  -o "${cdn_check_directory}/check-cdn-startup"
"${cdn_check_directory}/check-cdn-startup"

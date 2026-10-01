#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/.." && pwd)"
stall_check_directory="$(mktemp -d /tmp/playback-stall-check.XXXXXX)"
trap 'rm -rf -- "${stall_check_directory}"' EXIT

xcrun swiftc -parse-as-library \
  -module-cache-path "${stall_check_directory}/module-cache" \
  "${repository_root}/BilibiliLive/Component/Player/PlaybackStallMonitor.swift" \
  "${script_directory}/check-playback-stall.swift" \
  -o "${stall_check_directory}/check-playback-stall"
"${stall_check_directory}/check-playback-stall"

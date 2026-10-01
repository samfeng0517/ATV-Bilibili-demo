#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${script_directory}/.." && pwd)"
player_exit_check_directory="$(mktemp -d /tmp/player-exit-check.XXXXXX)"
trap 'rm -rf -- "${player_exit_check_directory}"' EXIT

xcrun swiftc -parse-as-library \
  -module-cache-path "${player_exit_check_directory}/module-cache" \
  "${repository_root}/BilibiliLive/Component/Player/PlayerExitConfirmation.swift" \
  "${script_directory}/check-player-exit.swift" \
  -o "${player_exit_check_directory}/check-player-exit"
"${player_exit_check_directory}/check-player-exit"

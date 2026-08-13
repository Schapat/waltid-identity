#!/usr/bin/env bash
set -euo pipefail

ADB_BIN="${ADB_BIN:-adb}"
ANDROID_SERIAL="${ANDROID_SERIAL:-}"
MIN_GMS_VERSION="${MIN_GMS_VERSION:-26.29.32}"
GMS_READY_TIMEOUT_SECONDS="${GMS_READY_TIMEOUT_SECONDS:-300}"
GMS_STABILITY_SECONDS="${GMS_STABILITY_SECONDS:-15}"
GMS_POLL_SECONDS="${GMS_POLL_SECONDS:-2}"

adb_cmd() {
  if [[ -n "$ANDROID_SERIAL" ]]; then
    "$ADB_BIN" -s "$ANDROID_SERIAL" "$@"
  else
    "$ADB_BIN" "$@"
  fi
}

adb_shell() {
  adb_cmd shell "$@" | tr -d '\r'
}

gms_details() {
  adb_shell dumpsys package com.google.android.gms 2>/dev/null
}

gms_version_name() {
  gms_details | sed -n 's/.*versionName=\([^[:space:]]*\).*/\1/p' | head -n 1
}

gms_version_code() {
  gms_details | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -n 1
}

gms_pid() {
  adb_shell pidof com.google.android.gms | tr '\n' ' ' | xargs
}

version_at_least() {
  local current_major current_minor current_patch
  local minimum_major minimum_minor minimum_patch
  IFS=. read -r current_major current_minor current_patch <<< "$1"
  IFS=. read -r minimum_major minimum_minor minimum_patch <<< "$2"

  [[ "${current_major:-}" =~ ^[0-9]+$ ]] || return 1
  [[ "${current_minor:-}" =~ ^[0-9]+$ ]] || return 1
  [[ "${current_patch:-}" =~ ^[0-9]+$ ]] || return 1
  [[ "${minimum_major:-}" =~ ^[0-9]+$ ]] || return 1
  [[ "${minimum_minor:-}" =~ ^[0-9]+$ ]] || return 1
  [[ "${minimum_patch:-}" =~ ^[0-9]+$ ]] || return 1

  if (( current_major != minimum_major )); then
    (( current_major > minimum_major ))
  elif (( current_minor != minimum_minor )); then
    (( current_minor > minimum_minor ))
  else
    (( current_patch >= minimum_patch ))
  fi
}

gms_snapshot() {
  local version pid
  version="$(gms_version_name)"
  pid="$(gms_pid)"
  printf '%s|%s\n' "$version" "$pid"
}

prepare_android_dc_api_device() {
  adb_cmd wait-for-device

  local deadline=$((SECONDS + GMS_READY_TIMEOUT_SECONDS))
  local last_logged_version=""
  local stable_snapshot=""
  local stable_for_seconds=0

  echo "DC API device preflight: waiting for Android boot and package manager"
  while (( SECONDS < deadline )); do
    local boot_completed
    boot_completed="$(adb_shell getprop sys.boot_completed)"
    if [[ "$boot_completed" != "1" ]]; then
      sleep "$GMS_POLL_SECONDS"
      continue
    fi

    if ! adb_shell pm path com.google.android.gms >/dev/null 2>&1; then
      echo "DC API device preflight: package manager has no Google Play services yet"
      sleep "$GMS_POLL_SECONDS"
      continue
    fi

    local version code
    version="$(gms_version_name)"
    code="$(gms_version_code)"
    if [[ "$version" != "$last_logged_version" ]]; then
      echo "DC API device preflight: Google Play services version=$version versionCode=$code"
      last_logged_version="$version"
    fi

    if ! version_at_least "$version" "$MIN_GMS_VERSION"; then
      echo "DC API device preflight: waiting for Google Play services >= $MIN_GMS_VERSION (found $version)"
      sleep "$GMS_POLL_SECONDS"
      continue
    fi

    local snapshot
    snapshot="$(gms_snapshot)"
    if [[ "$snapshot" == *"|" ]]; then
      stable_snapshot=""
      stable_for_seconds=0
      sleep "$GMS_POLL_SECONDS"
      continue
    fi

    if [[ "$snapshot" == "$stable_snapshot" ]]; then
      stable_for_seconds=$((stable_for_seconds + GMS_POLL_SECONDS))
    else
      stable_snapshot="$snapshot"
      stable_for_seconds=0
    fi

    echo "DC API device preflight: GMS snapshot=$snapshot stableFor=${stable_for_seconds}s"
    if (( stable_for_seconds >= GMS_STABILITY_SECONDS )); then
      GMS_VERSION_BEFORE_TESTS="${snapshot%%|*}"
      GMS_VERSION_CODE_BEFORE_TESTS="$code"
      export GMS_VERSION_BEFORE_TESTS GMS_VERSION_CODE_BEFORE_TESTS
      echo "DC API device preflight: Google Play services stabilized at $GMS_VERSION_BEFORE_TESTS (versionCode=$GMS_VERSION_CODE_BEFORE_TESTS)"
      return 0
    fi
    sleep "$GMS_POLL_SECONDS"
  done

  local final_version final_code
  final_version="$(gms_version_name || true)"
  final_code="$(gms_version_code || true)"
  echo "::error::DC API environment did not stabilize: GMS=$final_version versionCode=$final_code required>=$MIN_GMS_VERSION" >&2
  return 1
}

assert_android_dc_api_device_unchanged() {
  local after_version after_code after_pid after_snapshot
  after_version="$(gms_version_name || true)"
  after_code="$(gms_version_code || true)"
  after_pid="$(gms_pid || true)"
  after_snapshot="$after_version|$after_pid"
  echo "DC API device postflight: GMS snapshot=$after_snapshot versionCode=$after_code"
  echo "GMS_VERSION_BEFORE_TESTS=${GMS_VERSION_BEFORE_TESTS:-<unset>}"
  echo "GMS_VERSION_CODE_BEFORE_TESTS=${GMS_VERSION_CODE_BEFORE_TESTS:-<unset>}"
  echo "GMS_VERSION_AFTER_TESTS=$after_version"
  echo "GMS_VERSION_CODE_AFTER_TESTS=$after_code"

  if [[ "${GMS_VERSION_BEFORE_TESTS:-}" != "$after_version" ||
    "${GMS_VERSION_CODE_BEFORE_TESTS:-}" != "$after_code"
  ]]; then
    echo "::error::Google Play services changed during the DC API test suite: before=${GMS_VERSION_BEFORE_TESTS:-<unset>}/${GMS_VERSION_CODE_BEFORE_TESTS:-<unset>} after=$after_version/$after_code" >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  prepare_android_dc_api_device
fi

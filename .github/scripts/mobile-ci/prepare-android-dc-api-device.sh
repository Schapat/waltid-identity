#!/usr/bin/env bash
set -euo pipefail

ADB_BIN="${ADB_BIN:-adb}"
ANDROID_SERIAL="${ANDROID_SERIAL:-}"
MIN_GMS_VERSION="${MIN_GMS_VERSION:-26.29.32}"
GMS_READY_TIMEOUT_SECONDS="${GMS_READY_TIMEOUT_SECONDS:-300}"
GMS_STABILITY_SECONDS="${GMS_STABILITY_SECONDS:-15}"
GMS_POLL_SECONDS="${GMS_POLL_SECONDS:-2}"
GMS_VALIDATION_TIMEOUT_SECONDS="${GMS_VALIDATION_TIMEOUT_SECONDS:-60}"

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
  adb_shell dumpsys package com.google.android.gms 2>/dev/null || true
}

gms_version_name() {
  gms_details | sed -n 's/.*versionName=\([^[:space:]]*\).*/\1/p' | head -n 1
}

gms_version_code() {
  gms_details | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -n 1
}

gms_pid() {
  adb_shell pidof com.google.android.gms 2>/dev/null |
    tr '\n' ' ' |
    xargs || true
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

current_foreground_package() {
  adb_shell dumpsys activity activities 2>/dev/null |
    sed -n -E 's/.*(mResumedActivity|topResumedActivity|ResumedActivity)[=:].* u0 ([^/[:space:]]+)\/.*/\2/p' |
    head -n 1
}

home_activity() {
  adb_shell cmd package resolve-activity --brief \
    -a android.intent.action.MAIN \
    -c android.intent.category.HOME 2>/dev/null |
    awk '/\// { print $NF }' |
    tail -n 1
}

log_android_dc_api_device_identity() {
  local sdk release build fingerprint avd emulator_version home foreground gms_state
  sdk="$(adb_shell getprop ro.build.version.sdk || true)"
  release="$(adb_shell getprop ro.build.version.release || true)"
  build="$(adb_shell getprop ro.build.id || true)"
  fingerprint="$(adb_shell getprop ro.build.fingerprint || true)"
  avd="$(adb_cmd emu avd name 2>/dev/null | tr -d '\r' | head -n 1 || true)"
  emulator_version="<unavailable>"
  if [[ -n "${ANDROID_HOME:-}" && -x "$ANDROID_HOME/emulator/emulator" ]]; then
    emulator_version="$($ANDROID_HOME/emulator/emulator -version 2>&1 | head -n 1 || true)"
  fi
  home="$(home_activity || true)"
  foreground="$(current_foreground_package || true)"
  gms_state="$(adb_shell cmd activity get-uid-state com.google.android.gms 2>/dev/null || true)"

  echo "DC API device identity: serial=${ANDROID_SERIAL:-<default>} avd=${avd:-<unknown>}"
  echo "DC API device identity: adbState=$(adb_cmd get-state 2>/dev/null || true) bootCompleted=$(adb_shell getprop sys.boot_completed || true)"
  echo "DC API device identity: api=$sdk release=$release build=$build"
  echo "DC API device identity: fingerprint=$fingerprint"
  echo "DC API device identity: emulator=$emulator_version"
  echo "DC API device identity: home=$home foreground=$foreground"
  echo "DC API device identity: GMS version=$(gms_version_name || true) versionCode=$(gms_version_code || true) pid=$(gms_pid || true) uidState=$gms_state"
}

assert_android_dc_api_launcher_health() {
  local resolved_activity home_package launcher_pid foreground start_output anr_output
  resolved_activity="$(home_activity || true)"
  home_package="${resolved_activity%%/*}"

  if [[ -z "$resolved_activity" || -z "$home_package" || "$home_package" == "$resolved_activity" ]]; then
    echo "::error::DC API system UI health check could not resolve a HOME activity" >&2
    log_android_dc_api_device_identity
    return 1
  fi

  start_output="$(adb_shell am start -W \
    -a android.intent.action.MAIN \
    -c android.intent.category.HOME \
    -f 0x10000000 2>&1 || true)"
  echo "DC API system UI health: resolvedHome=$resolved_activity"
  echo "$start_output"
  if ! grep -q 'Status: ok' <<< "$start_output"; then
    echo "::error::DC API system UI health check could not start HOME: $resolved_activity" >&2
    log_android_dc_api_device_identity
    return 1
  fi

  launcher_pid="$(adb_shell pidof "$home_package" || true)"
  foreground="$(current_foreground_package || true)"
  if [[ -z "$launcher_pid" || "$foreground" != "$home_package" ]]; then
    echo "::error::DC API launcher is not healthy: package=$home_package pid=${launcher_pid:-<missing>} foreground=${foreground:-<missing>}" >&2
    log_android_dc_api_device_identity
    return 1
  fi

  anr_output="$(adb_shell dumpsys window windows 2>/dev/null || true)"
  if grep -Eqi 'Application Not Responding|is not responding' <<< "$anr_output"; then
    echo "::error::DC API system UI health found an ANR/crash-dialog marker for HOME" >&2
    log_android_dc_api_device_identity
    return 1
  fi

  echo "DC API system UI health: package=$home_package pid=$launcher_pid foreground=$foreground"
}

record_gms_baseline() {
  local snapshot="$1"
  local code="$2"
  GMS_VERSION_BEFORE_TESTS="${snapshot%%|*}"
  GMS_VERSION_CODE_BEFORE_TESTS="$code"
  export GMS_VERSION_BEFORE_TESTS GMS_VERSION_CODE_BEFORE_TESTS
  echo "DC API device preflight: Google Play services stabilized at $GMS_VERSION_BEFORE_TESTS (versionCode=$GMS_VERSION_CODE_BEFORE_TESTS)"
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
      record_gms_baseline "$snapshot" "$code"
      log_android_dc_api_device_identity
      assert_android_dc_api_launcher_health
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

validate_android_dc_api_device() {
  adb_cmd wait-for-device
  adb_cmd get-state >/dev/null

  local deadline=$((SECONDS + GMS_VALIDATION_TIMEOUT_SECONDS))
  local stable_snapshot=""
  local stable_for_seconds=0

  echo "DC API device validation: validating restored Android/GMS baseline"
  while (( SECONDS < deadline )); do
    local boot_completed
    boot_completed="$(adb_shell getprop sys.boot_completed)"
    if [[ "$boot_completed" != "1" ]]; then
      sleep "$GMS_POLL_SECONDS"
      continue
    fi

    adb_shell pm list packages >/dev/null
    if ! adb_shell pm path com.google.android.gms >/dev/null 2>&1; then
      echo "::error::Restored DC API AVD has no Google Play services package" >&2
      log_android_dc_api_device_identity
      return 1
    fi

    local version code pid snapshot
    version="$(gms_version_name)"
    code="$(gms_version_code)"
    pid="$(gms_pid)"
    echo "DC API device validation: GMS version=$version versionCode=$code pid=${pid:-<missing>}"
    if [[ -z "$version" || -z "$code" ]]; then
      sleep "$GMS_POLL_SECONDS"
      continue
    fi
    if ! version_at_least "$version" "$MIN_GMS_VERSION"; then
      echo "::error::Restored DC API AVD has GMS $version/$code, required >= $MIN_GMS_VERSION" >&2
      log_android_dc_api_device_identity
      return 1
    fi
    if [[ -z "$pid" ]]; then
      echo "::error::Restored DC API AVD has no running Google Play services process" >&2
      log_android_dc_api_device_identity
      return 1
    fi

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
    echo "DC API device validation: GMS snapshot=$snapshot stableFor=${stable_for_seconds}s"
    if (( stable_for_seconds >= GMS_STABILITY_SECONDS )); then
      record_gms_baseline "$snapshot" "$code"
      log_android_dc_api_device_identity
      assert_android_dc_api_launcher_health
      return 0
    fi
    sleep "$GMS_POLL_SECONDS"
  done

  echo "::error::Restored DC API AVD did not reach a stable healthy baseline within ${GMS_VALIDATION_TIMEOUT_SECONDS}s" >&2
  log_android_dc_api_device_identity
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

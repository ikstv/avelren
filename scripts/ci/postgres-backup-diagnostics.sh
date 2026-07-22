#!/usr/bin/env bash

diagnostics_script='scripts/ci/postgres-backup-test.sh'
diagnostics_initialized=0
diagnostics_finished=0
diagnostics_case_open=0
diagnostics_failure_recorded=0
diagnostics_secondary_cleanup_failure=0
diagnostics_current_case=
diagnostics_current_assertion='unexpected-command-failure'
diagnostics_failure_phase_override=
diagnostics_failed_case=
diagnostics_test_id=unassigned
diagnostics_dir=
diagnostics_report=
diagnostics_case_ids=()
diagnostics_case_descriptions=()
diagnostics_completed_cases=()
diagnostics_skipped_cases=()
diagnostics_skipped_reasons=()

diagnostics_valid_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
}

diagnostics_safe_id() {
  if diagnostics_valid_id "$1"; then
    printf '%s' "$1"
  else
    printf '%s' invalid-diagnostic-id
  fi
}

diagnostics_safe_kind() {
  case "$1" in
    assertion|file|marker|mode|owner|owner-mode|status|value) printf '%s' "$1" ;;
    *) printf '%s' invalid ;;
  esac
}

diagnostics_value_allowed() {
  local kind="$1" value="$2"
  [ "$value" = redacted ] && return 0
  case "$kind" in
    assertion) [[ "$value" =~ ^(accepted|entries-present|empty|failed|known|pass|rejected|unknown)$ ]] ;;
    file) [[ "$value" =~ ^(absent|present|unavailable)$ ]] ;;
    marker) [[ "$value" =~ ^(absent|present|unavailable)$ ]] ;;
    mode) [[ "$value" =~ ^([0-7]{3,4}|unavailable)$ ]] ;;
    owner) [[ "$value" =~ ^([0-9]+:[0-9]+|unavailable)$ ]] ;;
    owner-mode) [[ "$value" =~ ^([0-9]+:[0-9]+:[0-7]{3,4}|unavailable)$ ]] ;;
    status)
      if [ "$value" = nonzero ]; then
        return 0
      fi
      [[ "$value" =~ ^[0-9]{1,3}$ ]] && [ "$value" -le 255 ]
      ;;
    value) [[ "$value" =~ ^(empty|nonempty)$ ]] ;;
    *) return 1 ;;
  esac
}

diagnostics_safe_value() {
  local kind="$1" value="$2"
  if diagnostics_value_allowed "$kind" "$value"; then
    printf '%s' "$value"
  else
    printf '%s' redacted
  fi
}

diagnostics_report_line() {
  [ "$diagnostics_initialized" -eq 1 ] || return 0
  printf '%s\n' "$1" >>"$diagnostics_report"
}

diagnostics_case_registered() {
  local expected="$1" case_id
  for case_id in "${diagnostics_case_ids[@]}"; do
    [ "$case_id" != "$expected" ] || return 0
  done
  return 1
}

diagnostics_case_completed() {
  local expected="$1" case_id
  for case_id in "${diagnostics_completed_cases[@]}"; do
    [ "$case_id" != "$expected" ] || return 0
  done
  return 1
}

diagnostics_case_skipped() {
  local expected="$1" case_id
  for case_id in "${diagnostics_skipped_cases[@]}"; do
    [ "$case_id" != "$expected" ] || return 0
  done
  return 1
}

diagnostics_case_description() {
  local expected="$1" index
  for index in "${!diagnostics_case_ids[@]}"; do
    if [ "${diagnostics_case_ids[$index]}" = "$expected" ]; then
      printf '%s' "${diagnostics_case_descriptions[$index]}"
      return 0
    fi
  done
  return 1
}

diagnostics_init() {
  local specification case_id description base
  diagnostics_case_ids=()
  diagnostics_case_descriptions=()
  for specification in "$@"; do
    case_id="${specification%%|*}"
    description="${specification#*|}"
    diagnostics_valid_id "$case_id" || {
      printf '%s\n' 'Invalid diagnostic case ID.' >&2
      return 2
    }
    if [ "$description" = "$specification" ] || [ -z "$description" ]; then
      printf '%s\n' 'Missing diagnostic case description.' >&2
      return 2
    fi
    if diagnostics_case_registered "$case_id"; then
      printf '%s\n' 'Duplicate diagnostic case ID.' >&2
      return 2
    fi
    diagnostics_case_ids+=("$case_id")
    diagnostics_case_descriptions+=("$description")
  done

  base="${RUNNER_TEMP:-/tmp}"
  diagnostics_dir="$base/postgres-backup-safety-diagnostics"
  diagnostics_report="$diagnostics_dir/report.txt"
  if [ -e "$diagnostics_dir" ] || [ -L "$diagnostics_dir" ]; then
    printf '%s\n' 'Diagnostic directory already exists.' >&2
    return 2
  fi
  umask 077
  mkdir -m 700 -- "$diagnostics_dir"
  : >"$diagnostics_report"
  chmod 600 "$diagnostics_report"
  diagnostics_initialized=1
  diagnostics_report_line 'schema=avelren-postgres-backup-safety-diagnostics-v1'
  for case_id in "${diagnostics_case_ids[@]}"; do
    diagnostics_report_line "case_index=$case_id"
  done

  printf '%s\n' 'PostgreSQL backup safety case index:'
  for index in "${!diagnostics_case_ids[@]}"; do
    printf 'CASE %s — %s\n' "${diagnostics_case_ids[$index]}" "${diagnostics_case_descriptions[$index]}"
  done
  trap 'diagnostics_err_trap "$?" "$LINENO"' ERR
  trap 'diagnostics_timeout_trap "$LINENO"' TERM
  trap 'diagnostics_early_exit "$?" "$LINENO"' EXIT
}

diagnostics_set_test_id() {
  local value="${1##*/}"
  if [[ "$value" =~ ^avelren-backup-test\.[A-Za-z0-9]{6,16}$ ]] || [ "$value" = diagnostics-self-test ]; then
    diagnostics_test_id="$value"
  else
    diagnostics_test_id=invalid-test-id
  fi
}

diagnostics_set_assertion() {
  diagnostics_current_assertion="$(diagnostics_safe_id "$1")"
}

diagnostics_has_failure() {
  [ "$diagnostics_failure_recorded" -eq 1 ]
}

diagnostics_failure_phase() {
  case "$1" in
    harness-setup) printf '%s' setup ;;
    harness-cleanup) printf '%s' cleanup ;;
    runtime-root-runner) printf '%s' dependency ;;
    historical-nonempty) printf '%s' historical-fixture ;;
    *) printf '%s' assertion ;;
  esac
}

begin_case() {
  local case_id="$1" description
  diagnostics_case_registered "$case_id" || {
    diagnostics_current_case=diagnostic-framework
    diagnostics_record_failure 2 "$LINENO" invalid-case-id status 0 2
    exit 2
  }
  [ "$diagnostics_case_open" -eq 0 ] || {
    diagnostics_record_failure 2 "$LINENO" nested-case status 0 2
    exit 2
  }
  if diagnostics_case_completed "$case_id" || diagnostics_case_skipped "$case_id"; then
    diagnostics_current_case="$case_id"
    diagnostics_record_failure 2 "$LINENO" repeated-case status 0 2
    exit 2
  fi
  description="$(diagnostics_case_description "$case_id")"
  diagnostics_current_case="$case_id"
  diagnostics_current_assertion=case-body
  diagnostics_case_open=1
  printf '::group::CASE %s — %s\n' "$case_id" "$description"
}

pass_case() {
  local case_id="$1"
  if [ "$diagnostics_case_open" -ne 1 ] || [ "$diagnostics_current_case" != "$case_id" ]; then
    diagnostics_record_failure 2 "$LINENO" pass-case-mismatch status 0 2
    exit 2
  fi
  diagnostics_completed_cases+=("$case_id")
  diagnostics_report_line "completed_case=$case_id"
  printf 'PASS: %s\n' "$case_id"
  printf '%s\n' '::endgroup::'
  diagnostics_current_case=
  diagnostics_current_assertion='unexpected-command-failure'
  diagnostics_case_open=0
}

skip_case() {
  local case_id="$1" reason="$2"
  diagnostics_case_registered "$case_id" || return 2
  diagnostics_valid_id "$reason" || return 2
  diagnostics_case_completed "$case_id" && return 2
  diagnostics_case_skipped "$case_id" && return 2
  diagnostics_skipped_cases+=("$case_id")
  diagnostics_skipped_reasons+=("$reason")
}

skip_remaining_cases() {
  local reason="$1" case_id
  for case_id in "${diagnostics_case_ids[@]}"; do
    diagnostics_case_completed "$case_id" && continue
    diagnostics_case_skipped "$case_id" && continue
    [ "$case_id" = "$diagnostics_failed_case" ] && continue
    if [ "$diagnostics_secondary_cleanup_failure" -eq 1 ] && [ "$case_id" = harness-cleanup ]; then continue; fi
    skip_case "$case_id" "$reason"
  done
}

diagnostics_close_failed_cleanup() {
  printf '%s\n' 'FAIL: harness-cleanup' >&2
  printf '%s\n' 'assertion: cleanup-state' >&2
  printf '%s\n' 'expected: assertion pass' >&2
  printf '%s\n' 'actual: failed' >&2
  printf '%s\n' '::endgroup::' >&2
  diagnostics_secondary_cleanup_failure=1
  diagnostics_report_line 'secondary_failed_case=harness-cleanup'
  diagnostics_current_case=
  diagnostics_current_assertion='unexpected-command-failure'
  diagnostics_case_open=0
}

diagnostics_record_failure() {
  local status="$1" line="$2" assertion="$3" expected_kind="$4"
  local expected_value actual_value failure_phase
  expected_kind="$(diagnostics_safe_kind "$expected_kind")"
  expected_value="$(diagnostics_safe_value "$expected_kind" "$5")"
  actual_value="$(diagnostics_safe_value "$expected_kind" "$6")"
  assertion="$(diagnostics_safe_id "$assertion")"
  [[ "$line" =~ ^[0-9]+$ ]] || line=0
  if ! [[ "$status" =~ ^[0-9]{1,3}$ ]] || [ "$status" -gt 255 ]; then status=1; fi
  [ "$diagnostics_failure_recorded" -eq 0 ] || return 0
  trap - ERR TERM
  diagnostics_failure_recorded=1
  diagnostics_failed_case="${diagnostics_current_case:-unassigned}"
  if [ -n "$diagnostics_failure_phase_override" ]; then
    failure_phase="$diagnostics_failure_phase_override"
  else
    failure_phase="$(diagnostics_failure_phase "$diagnostics_failed_case")"
  fi
  diagnostics_case_open=0
  diagnostics_report_line 'result=FAIL'
  diagnostics_report_line "case_id=$diagnostics_failed_case"
  diagnostics_report_line "failure_phase=$failure_phase"
  diagnostics_report_line "assertion_id=$assertion"
  diagnostics_report_line "script=$diagnostics_script"
  diagnostics_report_line "line=$line"
  diagnostics_report_line "exit_status=$status"
  diagnostics_report_line "expected_kind=$expected_kind"
  diagnostics_report_line "expected_value=$expected_value"
  diagnostics_report_line "actual_value=$actual_value"
  diagnostics_report_line "temp_id=$diagnostics_test_id"

  printf 'FAIL: %s\n' "$diagnostics_failed_case" >&2
  printf 'script: %s\n' "$diagnostics_script" >&2
  printf 'line: %s\n' "$line" >&2
  printf 'phase: %s\n' "$failure_phase" >&2
  printf 'assertion: %s\n' "$assertion" >&2
  printf 'expected: %s %s\n' "$expected_kind" "$expected_value" >&2
  printf 'actual: %s\n' "$actual_value" >&2
  printf 'temporary test directory: %s\n' "$diagnostics_test_id" >&2
  printf '%s\n' '::endgroup::' >&2
}

fail_case() {
  local assertion="$1" expected="${2:-pass}" actual="${3:-failed}"
  diagnostics_record_failure 1 "${BASH_LINENO[0]}" "$assertion" assertion "$expected" "$actual"
  trap - ERR
  exit 1
}

diagnostics_err_trap() {
  local status="$1" line="$2"
  trap - ERR TERM
  set +e
  diagnostics_record_failure "$status" "$line" "$diagnostics_current_assertion" status 0 "$status"
  exit "$status"
}

diagnostics_timeout_trap() {
  local line="$1"
  trap - ERR TERM
  set +e
  diagnostics_failure_phase_override=timeout
  diagnostics_record_failure 124 "$line" case-timeout status 0 124
  exit 124
}

diagnostics_early_exit() {
  local status="$1" line="$2" finish_status=0
  trap - EXIT ERR TERM
  set +e
  if [ "$status" -ne 0 ] && [ "$diagnostics_failure_recorded" -eq 0 ]; then
    diagnostics_record_failure "$status" "$line" explicit-exit status 0 "$status"
  fi
  diagnostics_finish "$status" not-run || finish_status=$?
  if [ "$status" -eq 0 ] && [ "$finish_status" -ne 0 ]; then status="$finish_status"; fi
  exit "$status"
}

assert_status() {
  local expected="$1" actual="$2" assertion="$3"
  diagnostics_current_assertion="$assertion"
  [ "$actual" -eq "$expected" ] || {
    diagnostics_record_failure 1 "${BASH_LINENO[0]}" "$assertion" status "$expected" "$actual"
    trap - ERR
    exit 1
  }
}

assert_nonzero_status() {
  local actual="$1" assertion="$2"
  diagnostics_current_assertion="$assertion"
  [ "$actual" -ne 0 ] || {
    diagnostics_record_failure 1 "${BASH_LINENO[0]}" "$assertion" status nonzero "$actual"
    trap - ERR
    exit 1
  }
}

assert_file_exists() {
  local path="$1" assertion="$2"
  diagnostics_current_assertion="$assertion"
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    diagnostics_record_failure 1 "${BASH_LINENO[0]}" "$assertion" file present absent
    trap - ERR
    exit 1
  fi
}

assert_file_absent() {
  local path="$1" assertion="$2"
  diagnostics_current_assertion="$assertion"
  if [ -e "$path" ] || [ -L "$path" ]; then
    diagnostics_record_failure 1 "${BASH_LINENO[0]}" "$assertion" file absent present
    trap - ERR
    exit 1
  fi
}

assert_contains() {
  local file="$1" marker="$2" assertion="$3" status=0 actual=absent
  diagnostics_current_assertion="$assertion"
  if grep -Fq -- "$marker" "$file" 2>/dev/null; then
    return 0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || actual=unavailable
  [ "$status" -eq 1 ] || status=2
  diagnostics_record_failure "$status" "${BASH_LINENO[0]}" "$assertion" marker present "$actual"
  trap - ERR
  exit "$status"
}

assert_contains_exact_line() {
  local file="$1" marker="$2" assertion="$3" status=0 actual=absent
  diagnostics_current_assertion="$assertion"
  if grep -Fxq -- "$marker" "$file" 2>/dev/null; then
    return 0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || actual=unavailable
  [ "$status" -eq 1 ] || status=2
  diagnostics_record_failure "$status" "${BASH_LINENO[0]}" "$assertion" marker present "$actual"
  trap - ERR
  exit "$status"
}

assert_not_contains() {
  local file="$1" marker="$2" assertion="$3" status=0 actual=present
  diagnostics_current_assertion="$assertion"
  if grep -Fq -- "$marker" "$file" 2>/dev/null; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -eq 1 ]; then
    return 0
  fi
  [ "$status" -eq 0 ] || actual=unavailable
  if [ "$status" -ne 0 ]; then status=2; else status=1; fi
  diagnostics_record_failure "$status" "${BASH_LINENO[0]}" "$assertion" marker absent "$actual"
  trap - ERR
  exit "$status"
}

assert_not_contains_ci() {
  local file="$1" marker="$2" assertion="$3" status=0 actual=present
  diagnostics_current_assertion="$assertion"
  if grep -Fqi -- "$marker" "$file" 2>/dev/null; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -eq 1 ]; then
    return 0
  fi
  [ "$status" -eq 0 ] || actual=unavailable
  if [ "$status" -ne 0 ]; then status=2; else status=1; fi
  diagnostics_record_failure "$status" "${BASH_LINENO[0]}" "$assertion" marker absent "$actual"
  trap - ERR
  exit "$status"
}

assert_owner_mode() {
  local expected="$1" actual="$2" assertion="$3"
  diagnostics_current_assertion="$assertion"
  [ "$actual" = "$expected" ] || {
    diagnostics_record_failure 1 "${BASH_LINENO[0]}" "$assertion" owner-mode "$expected" "$actual"
    trap - ERR
    exit 1
  }
}

assert_mode() {
  local path="$1" expected="$2" assertion="$3" actual
  diagnostics_current_assertion="$assertion"
  actual="$(stat -c '%a' "$path" 2>/dev/null || printf '%s' unavailable)"
  [ "$actual" = "$expected" ] || {
    diagnostics_record_failure 1 "${BASH_LINENO[0]}" "$assertion" mode "$expected" "$actual"
    trap - ERR
    exit 1
  }
}

assert_owner() {
  local path="$1" expected_uid="$2" expected_gid="$3" assertion="$4" actual
  diagnostics_current_assertion="$assertion"
  actual="$(stat -c '%u:%g' "$path" 2>/dev/null || printf '%s' unavailable)"
  [ "$actual" = "$expected_uid:$expected_gid" ] || {
    diagnostics_record_failure 1 "${BASH_LINENO[0]}" "$assertion" owner "$expected_uid:$expected_gid" "$actual"
    trap - ERR
    exit 1
  }
}

assert_command_succeeds() {
  local assertion="$1" status=0
  shift
  diagnostics_current_assertion="$assertion"
  if "$@"; then
    return 0
  else
    status=$?
  fi
  diagnostics_record_failure "$status" "${BASH_LINENO[0]}" "$assertion" status 0 "$status"
  trap - ERR
  exit "$status"
}

assert_nonempty() {
  local actual="$1" assertion="$2"
  diagnostics_current_assertion="$assertion"
  [ -n "$actual" ] || {
    diagnostics_record_failure 1 "${BASH_LINENO[0]}" "$assertion" value nonempty empty
    trap - ERR
    exit 1
  }
}

diagnostics_finish() {
  local primary_status="$1" cleanup_status="$2" index case_id reason overall missing_case='' report_cleanup_status=0
  [ "$diagnostics_finished" -eq 0 ] || return 0
  diagnostics_finished=1
  trap - EXIT ERR TERM
  set +e
  if [ "$primary_status" -ne 0 ] && [ "$diagnostics_failure_recorded" -eq 0 ]; then
    diagnostics_record_failure "$primary_status" 0 untrapped-failure status 0 "$primary_status"
  fi
  if [ "$cleanup_status" = fail ] && [ "$primary_status" -eq 0 ] && [ "$diagnostics_failure_recorded" -eq 0 ]; then
    diagnostics_current_case=harness-cleanup
    diagnostics_record_failure 1 0 cleanup assertion pass failed
  fi
  if [ "$diagnostics_failure_recorded" -eq 0 ]; then
    if [ "$diagnostics_case_open" -eq 1 ]; then
      missing_case="$diagnostics_current_case"
    else
      for case_id in "${diagnostics_case_ids[@]}"; do
        diagnostics_case_completed "$case_id" && continue
        diagnostics_case_skipped "$case_id" && continue
        if [ "$diagnostics_secondary_cleanup_failure" -eq 1 ] && [ "$case_id" = harness-cleanup ]; then continue; fi
        missing_case="$case_id"
        break
      done
      if [ -n "$missing_case" ]; then begin_case "$missing_case"; fi
    fi
    if [ -n "$missing_case" ]; then
      diagnostics_record_failure 1 0 case-not-executed assertion pass failed
    fi
  fi
  if [ "$diagnostics_failure_recorded" -eq 1 ]; then
    skip_remaining_cases not-reached-after-failure
  fi
  diagnostics_report_line "cleanup=$cleanup_status"
  if [ "$diagnostics_failure_recorded" -eq 1 ]; then
    overall=FAIL
  elif [ "${#diagnostics_skipped_cases[@]}" -gt 0 ]; then
    overall=PASS_WITH_SKIPS
    diagnostics_report_line 'result=PASS'
  else
    overall=PASS
    diagnostics_report_line 'result=PASS'
  fi
  diagnostics_report_line "overall_status=$overall"

  printf '%s\n' 'Completed cases:'
  for case_id in "${diagnostics_completed_cases[@]}"; do printf 'COMPLETED: %s\n' "$case_id"; done
  if [ "$diagnostics_failure_recorded" -eq 1 ]; then printf 'Failed case: %s\n' "$diagnostics_failed_case"; else printf '%s\n' 'Failed case: none'; fi
  if [ "$diagnostics_secondary_cleanup_failure" -eq 1 ]; then printf '%s\n' 'Secondary failed case: harness-cleanup'; fi
  printf '%s\n' 'Skipped cases:'
  for index in "${!diagnostics_skipped_cases[@]}"; do
    case_id="${diagnostics_skipped_cases[$index]}"
    reason="${diagnostics_skipped_reasons[$index]}"
    diagnostics_report_line "skipped_case=$case_id:$reason"
    printf 'SKIP: %s — %s\n' "$case_id" "$reason"
  done
  printf 'Cleanup: %s\n' "$cleanup_status"
  printf 'Overall status: %s\n' "$overall"

  if [ "$overall" != FAIL ]; then
    rm -f -- "$diagnostics_report" || report_cleanup_status=1
    rmdir -- "$diagnostics_dir" || report_cleanup_status=1
    if [ "$report_cleanup_status" -ne 0 ]; then printf '%s\n' 'Diagnostic report cleanup failed.' >&2; fi
  fi
  if [ "$overall" = FAIL ]; then return 1; fi
  return "$report_cleanup_status"
}

diagnostics_guard() {
  local report="$1" report_dir line key value size expected_uid expected_gid secret_status=0
  local expected_kind_value='' expected_value_value='' actual_value_value='' failed_id='' failure_phase_value=''
  local schema_count=0 result_count=0 case_count=0 assertion_count=0 script_count=0
  local line_count=0 status_count=0 kind_count=0 expected_count=0 actual_count=0
  local temp_count=0 cleanup_count=0 overall_count=0 phase_count=0 secondary_count=0
  local index_count=0 terminal_count=0 completed_count=0 skipped_count=0 cleanup_value=
  local skipped_id skipped_reason
  local -A indexed_cases=() terminal_cases=()
  report_dir="${report%/*}"
  if [ "$report_dir" = "$report" ] || [ "${report##*/}" != report.txt ]; then printf '%s\n' 'Diagnostic report path is invalid.' >&2; return 1; fi
  [ "${report_dir##*/}" = postgres-backup-safety-diagnostics ] || { printf '%s\n' 'Diagnostic directory name is invalid.' >&2; return 1; }
  if [ ! -d "$report_dir" ] || [ -L "$report_dir" ]; then printf '%s\n' 'Diagnostic directory is unsafe.' >&2; return 1; fi
  if [ ! -f "$report" ] || [ -L "$report" ]; then printf '%s\n' 'Diagnostic report is not a regular file.' >&2; return 1; fi
  expected_uid="$(id -u)"
  expected_gid="$(id -g)"
  [ "$(stat -c '%a' "$report_dir")" = 700 ] || { printf '%s\n' 'Diagnostic directory mode is unsafe.' >&2; return 1; }
  [ "$(stat -c '%u:%g' "$report_dir")" = "$expected_uid:$expected_gid" ] || { printf '%s\n' 'Diagnostic directory owner is unsafe.' >&2; return 1; }
  [ "$(stat -c '%a' "$report")" = 600 ] || { printf '%s\n' 'Diagnostic report mode is unsafe.' >&2; return 1; }
  [ "$(stat -c '%u:%g' "$report")" = "$expected_uid:$expected_gid" ] || { printf '%s\n' 'Diagnostic report owner is unsafe.' >&2; return 1; }
  [ "$(stat -c '%h' "$report")" = 1 ] || { printf '%s\n' 'Diagnostic report link count is unsafe.' >&2; return 1; }
  size="$(stat -c '%s' "$report")" || return 1
  [ "$size" -le 32768 ] || { printf '%s\n' 'Diagnostic report is oversized.' >&2; return 1; }
  if grep -Eq 'intentional-secret-marker|fixture-password|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{35}|AKIA[0-9A-Z]{16}|"private_key"' "$report"; then
    secret_status=0
  else
    secret_status=$?
  fi
  [ "$secret_status" -eq 1 ] || { printf '%s\n' 'Diagnostic report contains forbidden or unreadable material.' >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    [ "${#line}" -le 256 ] || { printf '%s\n' 'Diagnostic report line is oversized.' >&2; return 1; }
    key="${line%%=*}"
    value="${line#*=}"
    [ "$value" != "$line" ] || { printf '%s\n' 'Malformed diagnostic report line.' >&2; return 1; }
    case "$key" in
      schema) [ "$value" = avelren-postgres-backup-safety-diagnostics-v1 ] || return 1; ((schema_count += 1)) ;;
      case_index)
        diagnostics_valid_id "$value" || return 1
        [ -z "${indexed_cases[$value]+present}" ] || return 1
        indexed_cases["$value"]=1
        ((index_count += 1))
        ;;
      completed_case)
        diagnostics_valid_id "$value" || return 1
        [ -n "${indexed_cases[$value]+present}" ] || return 1
        [ -z "${terminal_cases[$value]+present}" ] || return 1
        terminal_cases["$value"]=completed
        ((completed_count += 1))
        ((terminal_count += 1))
        ;;
      skipped_case)
        case "$value" in *:*:*) return 1 ;; *:*) ;; *) return 1 ;; esac
        skipped_id="${value%%:*}"
        skipped_reason="${value#*:}"
        diagnostics_valid_id "$skipped_id" || return 1
        diagnostics_valid_id "$skipped_reason" || return 1
        [ -n "${indexed_cases[$skipped_id]+present}" ] || return 1
        [ -z "${terminal_cases[$skipped_id]+present}" ] || return 1
        terminal_cases["$skipped_id"]=skipped
        ((skipped_count += 1))
        ((terminal_count += 1))
        ;;
      result) [ "$value" = FAIL ] || return 1; ((result_count += 1)) ;;
      case_id)
        diagnostics_valid_id "$value" || return 1
        [ -n "${indexed_cases[$value]+present}" ] || return 1
        [ -z "${terminal_cases[$value]+present}" ] || return 1
        failed_id="$value"
        terminal_cases["$value"]=failed
        ((case_count += 1))
        ((terminal_count += 1))
        ;;
      secondary_failed_case)
        [ "$value" = harness-cleanup ] || return 1
        [ -n "${indexed_cases[$value]+present}" ] || return 1
        [ -z "${terminal_cases[$value]+present}" ] || return 1
        terminal_cases["$value"]=secondary-failed
        ((secondary_count += 1))
        ((terminal_count += 1))
        ;;
      failure_phase)
        [[ "$value" =~ ^(assertion|cleanup|dependency|historical-fixture|setup|timeout)$ ]] || return 1
        failure_phase_value="$value"
        ((phase_count += 1))
        ;;
      assertion_id) diagnostics_valid_id "$value" || return 1; ((assertion_count += 1)) ;;
      script) [ "$value" = "$diagnostics_script" ] || return 1; ((script_count += 1)) ;;
      line) [[ "$value" =~ ^[0-9]+$ ]] || return 1; ((line_count += 1)) ;;
      exit_status)
        if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -gt 255 ]; then return 1; fi
        ((status_count += 1))
        ;;
      expected_kind) [[ "$value" =~ ^(assertion|file|marker|mode|owner|owner-mode|status|value)$ ]] || return 1; expected_kind_value="$value"; ((kind_count += 1)) ;;
      expected_value) [[ "$value" =~ ^[A-Za-z0-9:._-]{1,96}$ ]] || return 1; expected_value_value="$value"; ((expected_count += 1)) ;;
      actual_value) [[ "$value" =~ ^[A-Za-z0-9:._-]{1,96}$ ]] || return 1; actual_value_value="$value"; ((actual_count += 1)) ;;
      temp_id) [[ "$value" =~ ^(avelren-backup-test\.[A-Za-z0-9]{6,16}|diagnostics-self-test|invalid-test-id|unassigned)$ ]] || return 1; ((temp_count += 1)) ;;
      cleanup) [[ "$value" =~ ^(pass|fail|not-run)$ ]] || return 1; cleanup_value="$value"; ((cleanup_count += 1)) ;;
      overall_status) [ "$value" = FAIL ] || return 1; ((overall_count += 1)) ;;
      *) printf '%s\n' 'Unknown diagnostic report key.' >&2; return 1 ;;
    esac
  done <"$report"
  for value in "$schema_count" "$result_count" "$case_count" "$phase_count" "$assertion_count" "$script_count" "$line_count" "$status_count" "$kind_count" "$expected_count" "$actual_count" "$temp_count" "$cleanup_count" "$overall_count"; do
    [ "$value" -eq 1 ] || { printf '%s\n' 'Diagnostic report has missing or duplicate fields.' >&2; return 1; }
  done
  if [ "$index_count" -le 0 ] || [ "$terminal_count" -ne "$index_count" ]; then printf '%s\n' 'Diagnostic case accounting is incomplete.' >&2; return 1; fi
  diagnostics_value_allowed "$expected_kind_value" "$expected_value_value" || return 1
  diagnostics_value_allowed "$expected_kind_value" "$actual_value_value" || return 1
  if [ "$failure_phase_value" != timeout ]; then
    [ "$(diagnostics_failure_phase "$failed_id")" = "$failure_phase_value" ] || return 1
  fi
  if [ "$cleanup_value" = fail ]; then
    if [ "$failed_id" = harness-cleanup ]; then
      [ "$secondary_count" -eq 0 ] || return 1
    else
      [ "$secondary_count" -eq 1 ] || return 1
    fi
  else
    [ "$secondary_count" -eq 0 ] || return 1
  fi
  [ "$terminal_count" -eq $((completed_count + skipped_count + case_count + secondary_count)) ] || return 1
  printf '%s\n' 'Sanitized diagnostic report validation passed.'
}

diagnostics_self_test() {
  local script="$1" base fail_runner redact_runner timeout_runner pass_runner output report redact_output redact_report
  local timeout_output timeout_report status=0 redact_status=0 timeout_status=0 self_test_failed=0
  local secret_marker='intentional-secret-marker-do-not-print'
  base="$(mktemp -d "${RUNNER_TEMP:-/tmp}/avelren-diagnostics-self-test.XXXXXX")"
  fail_runner="$base/fail-runner"
  redact_runner="$base/redact-runner"
  timeout_runner="$base/timeout-runner"
  pass_runner="$base/pass-runner"
  output="$base/failure-output.txt"
  redact_output="$base/redaction-output.txt"
  timeout_output="$base/timeout-output.txt"
  mkdir -m 700 "$fail_runner" "$redact_runner" "$timeout_runner" "$pass_runner"
  if env RUNNER_TEMP="$fail_runner" AVELREN_DIAGNOSTICS_SELF_TEST=0 AVELREN_DIAGNOSTICS_SELF_TEST_CHILD=fail bash "$script" >"$output" 2>&1; then
    status=0
  else
    status=$?
  fi
  report="$fail_runner/postgres-backup-safety-diagnostics/report.txt"
  [ "$status" -eq 86 ] || self_test_failed=1
  grep -Fq 'FAIL: diagnostics-self-test' "$output" || self_test_failed=1
  grep -Eq '^line: [0-9]+$' "$output" || self_test_failed=1
  grep -Fq 'assertion: intentional-self-test' "$output" || self_test_failed=1
  grep -Fq 'expected: status 0' "$output" || self_test_failed=1
  grep -Fq 'actual: 86' "$output" || self_test_failed=1
  [ -f "$report" ] || self_test_failed=1
  diagnostics_guard "$report" >/dev/null 2>&1 || self_test_failed=1

  if env RUNNER_TEMP="$redact_runner" AVELREN_DIAGNOSTICS_SELF_TEST=0 AVELREN_DIAGNOSTICS_SELF_TEST_CHILD=redact AVELREN_DIAGNOSTICS_SELF_TEST_SECRET="$secret_marker" bash "$script" >"$redact_output" 2>&1; then
    redact_status=0
  else
    redact_status=$?
  fi
  redact_report="$redact_runner/postgres-backup-safety-diagnostics/report.txt"
  [ "$redact_status" -eq 1 ] || self_test_failed=1
  [ -f "$redact_report" ] || self_test_failed=1
  grep -Fq 'assertion: intentional-self-test-redaction' "$redact_output" || self_test_failed=1
  grep -Fq 'actual: redacted' "$redact_output" || self_test_failed=1
  grep -Fq 'actual_value=redacted' "$redact_report" || self_test_failed=1
  if grep -Fq "$secret_marker" "$redact_output" "$redact_report" 2>/dev/null; then self_test_failed=1; fi
  diagnostics_guard "$redact_report" >/dev/null 2>&1 || self_test_failed=1

  if env RUNNER_TEMP="$timeout_runner" AVELREN_DIAGNOSTICS_SELF_TEST=0 AVELREN_DIAGNOSTICS_SELF_TEST_CHILD=timeout bash "$script" >"$timeout_output" 2>&1; then
    timeout_status=0
  else
    timeout_status=$?
  fi
  timeout_report="$timeout_runner/postgres-backup-safety-diagnostics/report.txt"
  [ "$timeout_status" -eq 124 ] || self_test_failed=1
  [ -f "$timeout_report" ] || self_test_failed=1
  grep -Fq 'phase: timeout' "$timeout_output" || self_test_failed=1
  grep -Fq 'assertion: case-timeout' "$timeout_output" || self_test_failed=1
  diagnostics_guard "$timeout_report" >/dev/null 2>&1 || self_test_failed=1

  if ! env RUNNER_TEMP="$pass_runner" AVELREN_DIAGNOSTICS_SELF_TEST=0 AVELREN_DIAGNOSTICS_SELF_TEST_CHILD=pass bash "$script" >/dev/null 2>&1; then self_test_failed=1; fi
  [ ! -e "$pass_runner/postgres-backup-safety-diagnostics" ] || self_test_failed=1
  case "$base" in
    "${RUNNER_TEMP:-/tmp}"/avelren-diagnostics-self-test.*) rm -rf -- "$base" ;;
    *) printf '%s\n' 'Refusing diagnostic self-test cleanup outside disposable scope.' >&2; return 1 ;;
  esac
  [ "$self_test_failed" -eq 0 ] || { printf '%s\n' 'Intentional diagnostic failure self-test failed.' >&2; return 1; }
  printf '%s\n' 'Intentional diagnostic failure self-test passed.'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -Eeuo pipefail
  case "${1:-}" in
    guard) [ "$#" -eq 2 ] || exit 2; diagnostics_guard "$2" ;;
    self-test) [ "$#" -eq 2 ] || exit 2; diagnostics_self_test "$2" ;;
    *) printf '%s\n' 'Usage: postgres-backup-diagnostics.sh guard <report> | self-test <harness>' >&2; exit 2 ;;
  esac
fi

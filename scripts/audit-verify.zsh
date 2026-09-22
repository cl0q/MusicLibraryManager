#!/usr/bin/env zsh
#
# audit-verify.zsh — runs the full MLM audit verification sequence on macOS.
#
# What it does (in order):
#   1. Records the environment (OS / Xcode / Swift / git).
#   2. swift build                — do Astra's test-support changes compile?
#   3. swift test (full suite)    — do the ~345 existing tests still pass?
#   4. Snapshot RECORD pass       — generates the 60 reference PNGs.
#   5. Snapshot COMPARE pass      — re-renders and compares against the references.
#   6. Lists the produced PNGs and any comparison-failure artifacts.
#
# Everything (stdout + stderr of every step) is mirrored into ONE timestamped
# log file. At the end it prints the log path plus a compact PASS/FAIL summary.
# Just paste the whole log file back into the chat.
#
# Usage:
#   cd <repo root, where Package.swift lives>
#   ./scripts/audit-verify.zsh                 # runs everything
#   ./scripts/audit-verify.zsh --skip-full-tests   # skip the big suite, snapshots only
#
# Nothing is committed. The script never aborts on the first failure — it runs
# every step so you get the complete picture in one go.

emulate -L zsh
setopt pipe_fail          # a piped command's failure is visible even through tee
# NOTE: intentionally NOT using `set -e` — we want every step to run.

# ----------------------------------------------------------------------------
# Options
# ----------------------------------------------------------------------------
RUN_FULL_TESTS=1
for arg in "$@"; do
  case "$arg" in
    --skip-full-tests) RUN_FULL_TESTS=0 ;;
    -h|--help)
      print "Usage: ./scripts/audit-verify.zsh [--skip-full-tests]"
      exit 0 ;;
    *) print "Unknown option: $arg"; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------
# Locate repo root and set up logging
# ----------------------------------------------------------------------------
SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
cd "$REPO_ROOT" || { print "Cannot cd to repo root"; exit 1; }

if [[ ! -f "Package.swift" ]]; then
  print "ERROR: Package.swift not found in $REPO_ROOT — run from the repo root."
  exit 1
fi

# One label for this exact OS / Xcode / architecture combination.
# The harness only accepts [A-Za-z0-9_-] (no dots — they would allow path
# traversal), so any invalid char in the derived label is replaced with '-'
# (e.g. macOS "27.0" -> "27-0", giving "macos-27-0-arm64").
_raw_snapshot_set="macos-$(sw_vers -productVersion 2>/dev/null)-$(uname -m)"
: ${MLM_SNAPSHOT_SET:="${_raw_snapshot_set//[^A-Za-z0-9_-]/-}"}
export MLM_SNAPSHOT_SET

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$REPO_ROOT/audit-run-$TIMESTAMP.log"

# Per-step exit codes, collected for the final summary.
typeset -A STEP_RC

# Mirror everything to the log file from here on.
exec > >(tee -a "$LOG_FILE") 2>&1

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
hr()  { print -- "--------------------------------------------------------------------------------"; }
section() {
  print ""
  hr
  print "### $1"
  print "### $(date '+%Y-%m-%d %H:%M:%S %z')"
  hr
}

# run <step-key> <human label> <command...> — logs, times, and records exit code.
run() {
  local key="$1"; shift
  local label="$1"; shift
  section "$label"
  print "\$ $*"
  print ""
  local start=$SECONDS
  "$@"
  local rc=$?
  local dur=$(( SECONDS - start ))
  STEP_RC[$key]=$rc
  print ""
  print ">>> [$key] exit=$rc  duration=${dur}s"
  return $rc
}

# ----------------------------------------------------------------------------
# Header
# ----------------------------------------------------------------------------
section "MLM AUDIT VERIFICATION — START"
print "Repo root      : $REPO_ROOT"
print "Log file       : $LOG_FILE"
print "Snapshot set   : $MLM_SNAPSHOT_SET"
print "Full test suite: $([[ $RUN_FULL_TESTS -eq 1 ]] && print yes || print 'no (--skip-full-tests)')"

# ----------------------------------------------------------------------------
# 1. Environment
# ----------------------------------------------------------------------------
section "ENVIRONMENT"
print "\$ sw_vers";        sw_vers 2>&1
print ""
print "\$ xcodebuild -version"; xcodebuild -version 2>&1
print ""
print "\$ xcode-select -p";     xcode-select -p 2>&1
print ""
print "\$ swift --version";     swift --version 2>&1
print ""
print "\$ uname -a";            uname -a 2>&1
print ""
print "\$ git rev-parse HEAD";  git rev-parse HEAD 2>&1
print ""
print "\$ git status --short";  git --no-pager status --short 2>&1

# ----------------------------------------------------------------------------
# 2. Build
# ----------------------------------------------------------------------------
run build "STEP 1/5 — swift build (compile check for the test-support changes)" \
  swift build

# ----------------------------------------------------------------------------
# 3. Full test suite (optional)
# ----------------------------------------------------------------------------
if [[ $RUN_FULL_TESTS -eq 1 ]]; then
  run full_tests "STEP 2/5 — swift test (full existing suite, ~345 tests)" \
    swift test
else
  section "STEP 2/5 — swift test (full suite) — SKIPPED (--skip-full-tests)"
  STEP_RC[full_tests]="skipped"
fi

# ----------------------------------------------------------------------------
# 4. Snapshot RECORD pass — generates the 60 reference PNGs
# ----------------------------------------------------------------------------
run snapshot_record "STEP 3/5 — snapshot RECORD (creates reference PNGs, overwrites intentionally)" \
  env MLM_SNAPSHOTS=1 MLM_SNAPSHOT_RECORD=1 swift test --filter Snapshots

# List what got produced.
section "PRODUCED REFERENCE PNGs — MLMTests/Snapshots/__Snapshots__/$MLM_SNAPSHOT_SET"
REF_DIR="MLMTests/Snapshots/__Snapshots__/$MLM_SNAPSHOT_SET"
if [[ -d "$REF_DIR" ]]; then
  print "\$ ls -la $REF_DIR"
  ls -la "$REF_DIR" 2>&1
  print ""
  print "PNG count: $(find "$REF_DIR" -name '*.png' | wc -l | tr -d ' ')"
else
  print "WARNING: reference directory not found: $REF_DIR"
fi

# ----------------------------------------------------------------------------
# 5. Snapshot COMPARE pass — re-render and diff against references
# ----------------------------------------------------------------------------
run snapshot_compare "STEP 4/5 — snapshot COMPARE (no reference updates)" \
  env MLM_SNAPSHOTS=1 swift test --filter Snapshots

# ----------------------------------------------------------------------------
# 6. Failure artifacts (if any)
# ----------------------------------------------------------------------------
section "STEP 5/5 — comparison failure artifacts (actual/diff images, if any)"
FAIL_DIR=".build/mlm-snapshot-failures/$MLM_SNAPSHOT_SET"
if [[ -d "$FAIL_DIR" ]]; then
  print "\$ ls -la $FAIL_DIR"
  ls -la "$FAIL_DIR" 2>&1
  print ""
  print "Failure artifact count: $(find "$FAIL_DIR" -type f | wc -l | tr -d ' ')"
  print "Open locally with:  open \"$FAIL_DIR\""
else
  print "No failure-artifact directory — comparison produced no diffs (or record/compare did not run)."
fi

# ----------------------------------------------------------------------------
# Final summary
# ----------------------------------------------------------------------------
section "SUMMARY"
rc_label() {
  case "$1" in
    0)       print "PASS" ;;
    skipped) print "SKIPPED" ;;
    "")      print "DID NOT RUN" ;;
    *)       print "FAIL (exit $1)" ;;
  esac
}
printf "%-32s %s\n" "swift build"              "$(rc_label ${STEP_RC[build]})"
printf "%-32s %s\n" "swift test (full suite)"  "$(rc_label ${STEP_RC[full_tests]})"
printf "%-32s %s\n" "snapshot RECORD"          "$(rc_label ${STEP_RC[snapshot_record]})"
printf "%-32s %s\n" "snapshot COMPARE"         "$(rc_label ${STEP_RC[snapshot_compare]})"
print ""
print "Snapshot set : $MLM_SNAPSHOT_SET"
print "Reference dir: $REF_DIR"
print "Log file     : $LOG_FILE"
print ""
print "=============================================================================="
print " DONE. Paste the ENTIRE log file back into the chat:"
print "   $LOG_FILE"
print " (Reveal it with:  open -R \"$LOG_FILE\"  — or  cat \"$LOG_FILE\" | pbcopy )"
print "=============================================================================="

# Exit non-zero if any executed step failed (handy for eyeballing $?).
for k in build full_tests snapshot_record snapshot_compare; do
  rc=${STEP_RC[$k]}
  [[ "$rc" == "skipped" || "$rc" == "0" || -z "$rc" ]] || exit 1
done
exit 0

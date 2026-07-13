#!/usr/bin/env bash
# Multi-seed reachability leg for one Atlas EVM planted twin.
#
# Runs `forge test --fuzz-seed <seed> -vv` from within a case's planted
# directory across every seed in ci/reachability_seeds.txt (N=16 by
# default). Every seed must exit non-zero AND print at least one
# `INVARIANT VIOLATED` marker. This upgrades the base atlas-all planted
# leg's one-seed catch to a deterministic N-of-N certification per case.
#
# Usage:
#   ci/reachability_leg.sh --case-dir <path> --label <human-label>
#     [--seeds-file <path>]
#
# The wrapper expects forge-std (and any per-case dep like OpenZeppelin
# v5) to already be installed under <case-dir>/lib/. atlas-all.yml
# handles the install; this script only runs seeds.
#
# See ../scripts/reachability/ in the caliperforge crypto-contributor
# repo for the canonical runner this mirrors.

set -uo pipefail

CASE_DIR=""
LABEL=""
SEEDS_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --case-dir)   CASE_DIR="$2"; shift 2 ;;
    --label)      LABEL="$2"; shift 2 ;;
    --seeds-file) SEEDS_FILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$CASE_DIR" ] || [ -z "$LABEL" ]; then
  echo "usage: $0 --case-dir <path> --label <human-label> [--seeds-file <path>]" >&2
  exit 2
fi

if [ -z "$SEEDS_FILE" ]; then
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  SEEDS_FILE="$script_dir/reachability_seeds.txt"
fi

if [ ! -d "$CASE_DIR" ]; then
  echo "case dir not found: $CASE_DIR" >&2
  exit 2
fi
if [ ! -f "$SEEDS_FILE" ]; then
  echo "seeds file not found: $SEEDS_FILE" >&2
  exit 2
fi

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
seeds=$(grep -vE '^\s*(#|$)' "$SEEDS_FILE")

total=0
failed=0
missed=""

{
  echo "## Multi-seed reachability: $LABEL"
  echo ""
  echo "case dir: \`$CASE_DIR\`  seeds file: \`$SEEDS_FILE\`"
  echo ""
  echo "| seed | outcome | markers |"
  echo "| --- | --- | --- |"
} >>"$summary"

pushd "$CASE_DIR" >/dev/null || exit 2

for seed in $seeds; do
  total=$((total + 1))
  out=$(forge test --fuzz-seed "$seed" -vv 2>&1)
  rc=$?
  markers=$(printf '%s\n' "$out" | grep -c "INVARIANT VIOLATED" || true)

  if [ "$rc" -ne 0 ] && [ "$markers" -gt 0 ]; then
    echo "$LABEL seed $seed: FAILED as required (rc=$rc, markers=$markers)"
    echo "| \`$seed\` | failed (required) | $markers |" >>"$summary"
    failed=$((failed + 1))
  elif [ "$rc" -eq 0 ]; then
    echo "$LABEL seed $seed: passed unexpectedly (rc=0). planted-twin escaped on this seed."
    echo "| \`$seed\` | ESCAPED (rc=0) | 0 |" >>"$summary"
    missed="$missed $seed"
  else
    echo "$LABEL seed $seed: rc=$rc but no INVARIANT VIOLATED marker; treating as escape."
    echo "| \`$seed\` | escape (no marker, rc=$rc) | 0 |" >>"$summary"
    printf '%s\n' "$out" | tail -20
    missed="$missed $seed"
  fi
done

popd >/dev/null

echo ""
if [ "$failed" -eq "$total" ]; then
  verdict="$LABEL reachability certified: yes ($failed/$total failed as required)"
  echo "$verdict"
  echo "" >>"$summary"
  echo "**$verdict**" >>"$summary"
  exit 0
fi

verdict="$LABEL reachability certified: no ($failed/$total failed; missed on seeds:$missed)"
echo "$verdict"
echo "" >>"$summary"
echo "**$verdict**" >>"$summary"
exit 1

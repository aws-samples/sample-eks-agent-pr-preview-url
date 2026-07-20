#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# preview-sweep.test.sh — BEHAVIORAL tests for the unattended reaper's fail-closed
# guards, exercising the REAL scripts/preview-sweep.sh (not a paraphrase) via a
# stubbed `kubectl` on PATH. This is the highest-consequence script in the repo
# (cron `kubectl delete namespace`), so its guards must be tested against the
# actual code.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWEEP="$ROOT/scripts/preview-sweep.sh"
pass=0; fail=0
ok()   { echo "  ✓ $1"; pass=$((pass+1)); }
bad()  { echo "  ✗ $1"; fail=$((fail+1)); }

# --- kubectl stub -----------------------------------------------------------
# A PATH shim that answers the exact calls preview-sweep.sh makes, from fixture
# files the test writes. Records every `delete namespace` into $REAPED.
STUB_DIR="$(mktemp -d)"; trap 'rm -rf "$STUB_DIR"' EXIT
export SWEEP_NS_LIST="$STUB_DIR/nslist"     # newline list of pr-<n> names (labeled set)
export SWEEP_REAPED="$STUB_DIR/reaped"      # kubectl delete records land here
export SWEEP_LABEL_MISSING="${SWEEP_LABEL_MISSING:-}"  # ns names (space list) whose label is absent
export SWEEP_CREATED_AT="$STUB_DIR/created" # "<ns> <iso8601>" lines for age lookups
: > "$SWEEP_REAPED"
cat > "$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
# Minimal kubectl stub for preview-sweep tests.
case "$*" in
  "get ns -l "*)                    # list labeled preview namespaces
    while read -r n; do [ -n "$n" ] && echo "$n"; done < "${SWEEP_NS_LIST:-/dev/null}" ;;
  "get ns "*"-o jsonpath={.metadata.creationTimestamp}"*)
    ns="$(echo "$*" | awk '{print $3}')"
    grep "^$ns " "${SWEEP_CREATED_AT:-/dev/null}" 2>/dev/null | awk '{print $2}' ;;
  "get ns "*"part-of"*)             # label re-check (Guard 6): print value unless missing
    ns="$(echo "$*" | awk '{print $3}')"
    case " $SWEEP_LABEL_MISSING " in *" $ns "*) echo "";; *) echo "preview-platform";; esac ;;
  "delete namespace "*)
    ns="$(echo "$*" | awk '{print $3}')"; echo "$ns" >> "${SWEEP_REAPED}" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/kubectl"
# stub helm so the reap path is side-effect-free
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/helm"; chmod +x "$STUB_DIR/helm"
export PATH="$STUB_DIR:$PATH"

run_sweep() { # args...  -> sets RC; resets reaped (output discarded)
  : > "$SWEEP_REAPED"
  bash "$SWEEP" "$@" >/dev/null 2>&1; RC=$?
}
reaped_count() { [ -s "$SWEEP_REAPED" ] && grep -c . "$SWEEP_REAPED" || echo 0; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
old_iso() { # 1 day ago, portable
  date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
  date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2000-01-01T00:00:00Z"
}

echo "preview-sweep.sh fail-closed guards (real script, stubbed kubectl):"

# Guard 1: no arg → abort, reap nothing
run_sweep
{ [ "$RC" -ne 0 ] && [ "$(reaped_count)" -eq 0 ]; } && ok "no-arg aborts (exit $RC, 0 reaped)" || bad "no-arg should abort without reaping (rc=$RC reaped=$(reaped_count))"

# Guard 2: empty open-set without allow → abort
printf 'pr-1\npr-2\n' > "$SWEEP_NS_LIST"
run_sweep ""
{ [ "$RC" -ne 0 ] && [ "$(reaped_count)" -eq 0 ]; } && ok "empty open-set refused (fail-closed)" || bad "empty open-set should refuse (rc=$RC reaped=$(reaped_count))"

# Guard 2 opt-out: empty + SWEEP_ALLOW_EMPTY=1 → allowed to proceed (old enough)
printf 'pr-1\n' > "$SWEEP_NS_LIST"; printf 'pr-1 %s\n' "$(old_iso)" > "$SWEEP_CREATED_AT"
SWEEP_ALLOW_EMPTY=1 SWEEP_MIN_AGE_MIN=0 run_sweep ""
{ [ "$RC" -eq 0 ] && [ "$(reaped_count)" -eq 1 ]; } && ok "empty + ALLOW_EMPTY reaps the orphan" || bad "ALLOW_EMPTY should reap (rc=$RC reaped=$(reaped_count))"

# Happy path: orphan (pr-2 not open) reaped, open (pr-1) kept
printf 'pr-1\npr-2\n' > "$SWEEP_NS_LIST"; printf 'pr-1 %s\npr-2 %s\n' "$(old_iso)" "$(old_iso)" > "$SWEEP_CREATED_AT"
SWEEP_MIN_AGE_MIN=0 run_sweep "1"
{ [ "$RC" -eq 0 ] && grep -qx pr-2 "$SWEEP_REAPED" && ! grep -qx pr-1 "$SWEEP_REAPED"; } \
  && ok "reaps the orphan (pr-2), keeps the open PR (pr-1)" || bad "happy path wrong (rc=$RC reaped=[$(tr '\n' ' ' <"$SWEEP_REAPED")])"

# Guard 5: reap ceiling — many orphans, low cap → abort, reap nothing
printf 'pr-10\npr-11\npr-12\npr-13\n' > "$SWEEP_NS_LIST"
{ for n in 10 11 12 13; do printf 'pr-%s %s\n' "$n" "$(old_iso)"; done; } > "$SWEEP_CREATED_AT"
SWEEP_MIN_AGE_MIN=0 SWEEP_MAX_REAP=2 run_sweep "1"
{ [ "$RC" -ne 0 ] && [ "$(reaped_count)" -eq 0 ]; } && ok "reap ceiling aborts a mass-orphan (SWEEP_MAX_REAP)" || bad "ceiling should abort (rc=$RC reaped=$(reaped_count))"

# Guard 4: age grace — a young orphan is skipped
printf 'pr-9\n' > "$SWEEP_NS_LIST"; printf 'pr-9 %s\n' "$(now_iso)" > "$SWEEP_CREATED_AT"
SWEEP_MIN_AGE_MIN=10 run_sweep "1"
{ [ "$RC" -eq 0 ] && [ "$(reaped_count)" -eq 0 ]; } && ok "age grace skips a just-created namespace" || bad "young ns should be skipped (rc=$RC reaped=$(reaped_count))"

# Guard 6: TOCTOU label re-check — label vanished at delete time → skip
printf 'pr-7\n' > "$SWEEP_NS_LIST"; printf 'pr-7 %s\n' "$(old_iso)" > "$SWEEP_CREATED_AT"
SWEEP_MIN_AGE_MIN=0 SWEEP_LABEL_MISSING="pr-7" run_sweep "1"
{ [ "$(reaped_count)" -eq 0 ]; } && ok "label re-check skips an unlabeled ns at delete time" || bad "unlabeled ns should be skipped (reaped=$(reaped_count))"

# DRY_RUN: plans but deletes nothing
printf 'pr-2\n' > "$SWEEP_NS_LIST"; printf 'pr-2 %s\n' "$(old_iso)" > "$SWEEP_CREATED_AT"
SWEEP_MIN_AGE_MIN=0 DRY_RUN=1 run_sweep "1"
{ [ "$RC" -eq 0 ] && [ "$(reaped_count)" -eq 0 ]; } && ok "DRY_RUN plans without deleting" || bad "DRY_RUN should not delete (rc=$RC reaped=$(reaped_count))"

echo ""
echo "preview-sweep: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

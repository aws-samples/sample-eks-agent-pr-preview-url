#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Reconcile preview namespaces against the open-PR set; reap orphans.
# Usage: preview-sweep.sh "<csv-of-open-pr-numbers>"
#
# Portable to bash 3.2 (macOS default): no `mapfile` (which 3.2 lacks and which,
# combined with `set -u`, would abort on the empty array). Iterates a plain
# word-split list instead.
#
# SAFETY — this script deletes namespaces unattended, so it fails CLOSED:
#   * The open-PR set must be passed EXPLICITLY as $1. If the argument is absent
#     the script aborts (an unset arg means the caller's PR lookup never ran).
#   * An EMPTY set ("no PRs open") is refused unless SWEEP_ALLOW_EMPTY=1, because
#     an empty string is indistinguishable from a failed GitHub API call — the
#     exact input that would otherwise reap every preview.
#   * A reap CEILING (SWEEP_MAX_REAP, default 10) aborts the run if more previews
#     than that look orphaned at once — a mass-orphan is almost always a bad
#     open-set, not reality. Raise it deliberately for a real large cleanup.
#   * Namespaces younger than SWEEP_MIN_AGE_MIN (default 10) are skipped, so a
#     preview created after the open-set snapshot isn't reaped in the race window.
#   * Only namespaces carrying the platform guard label AND matching ^pr-[0-9]+$
#     are ever considered, and the label is re-checked immediately before delete.
#   * DRY_RUN=1 prints the plan and deletes nothing.
set -uo pipefail

PLATFORM_LABEL="app.kubernetes.io/part-of=preview-platform"
SWEEP_ALLOW_EMPTY="${SWEEP_ALLOW_EMPTY:-0}"
SWEEP_MAX_REAP="${SWEEP_MAX_REAP:-10}"
SWEEP_MIN_AGE_MIN="${SWEEP_MIN_AGE_MIN:-10}"
DRY_RUN="${DRY_RUN:-0}"
HERE="$(cd "$(dirname "$0")" && pwd)"

die() { echo "sweep: ABORT — $*" >&2; exit 2; }

# --- Guard 1: the open-set must be passed explicitly (unset arg => lookup failed).
if [ "$#" -lt 1 ]; then
  die "no open-PR set argument. Pass \"\" only with SWEEP_ALLOW_EMPTY=1. Refusing to reap."
fi
OPEN="$1"

# --- Guard 2: fail closed on an empty set unless explicitly allowed.
if [ -z "$OPEN" ] && [ "$SWEEP_ALLOW_EMPTY" != "1" ]; then
  die "open-PR set is EMPTY. This looks like a failed PR lookup, not zero open PRs. \
Set SWEEP_ALLOW_EMPTY=1 if you truly have no open PRs and want everything reaped."
fi

# Only ever consider namespaces that carry the platform guard label AND look like pr-<n>.
names="$(kubectl get ns -l "$PLATFORM_LABEL" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -E '^pr-[0-9]+$' || true)"

# --- Guard 3: build the reap plan first (plan-then-apply), so we can sanity-check
# the count before deleting anything.
plan=""
total=0
now_s="$(date +%s)"
for ns in $names; do
  total=$((total+1))
  n="${ns#pr-}"
  # skip anything still open
  [[ ",$OPEN," == *",$n,"* ]] && continue
  # --- Guard 4: age grace — don't reap a namespace younger than the threshold.
  created="$(kubectl get ns "$ns" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"
  if [ -n "$created" ]; then
    # portable epoch parse — the timestamp is UTC (trailing Z), so parse it AS UTC:
    # GNU `date -u -d`, else BSD `date -j -u -f`. Without -u, BSD date reads the
    # UTC string in local time and skews the age by the local offset.
    c_s="$(date -u -d "$created" +%s 2>/dev/null || date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null || echo 0)"
    if [ "$c_s" -gt 0 ]; then
      age_min=$(( (now_s - c_s) / 60 ))
      if [ "$age_min" -lt "$SWEEP_MIN_AGE_MIN" ]; then
        echo "sweep: skip $ns (age ${age_min}m < ${SWEEP_MIN_AGE_MIN}m grace; PR #$n may be mid-open)"
        continue
      fi
    fi
  fi
  plan="$plan $ns"
done

# normalize plan → count
set -- $plan
reap_count="$#"

# --- Guard 5: reap ceiling — a mass-orphan is almost always a bad open-set.
if [ "$reap_count" -gt "$SWEEP_MAX_REAP" ]; then
  die "would reap $reap_count previews (> SWEEP_MAX_REAP=$SWEEP_MAX_REAP): [$plan ]. \
This looks like a bad open-set, not reality. Re-run with SWEEP_MAX_REAP raised if intended."
fi

if [ "$reap_count" -eq 0 ]; then
  echo "sweep complete: $total preview namespaces, 0 orphans, open=[$OPEN]"
  exit 0
fi

echo "sweep plan: reap $reap_count of $total previews →$plan (open=[$OPEN], dry_run=$DRY_RUN)"

reaped=0
for ns in $plan; do
  n="${ns#pr-}"
  # --- Guard 6: re-confirm the guard label immediately before deleting (TOCTOU).
  # `kubectl get ns NAME -l SELECTOR` is illegal (name + selector conflict), so
  # read the label value off the named namespace and compare.
  label_val="$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null)"
  if [ "$label_val" != "preview-platform" ]; then
    echo "sweep: skip $ns (guard label absent/changed at delete time: '${label_val}')"
    continue
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "sweep: DRY_RUN would reap $ns (PR #$n not open)"
    reaped=$((reaped+1))
    continue
  fi
  echo "sweep: $ns (PR #$n not open) -> teardown"
  # Drop the per-PR schema before the namespace, best-effort.
  bash "$HERE/drop-schema.sh" "$n" "$ns" >/dev/null 2>&1 || true
  helm uninstall web -n "$ns" >/dev/null 2>&1 || true
  kubectl delete namespace "$ns" --ignore-not-found --wait=false
  reaped=$((reaped+1))
done
echo "sweep complete: $total preview namespaces, $reaped reaped, open=[$OPEN]"

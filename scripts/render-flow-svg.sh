#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# render-flow-svg.sh — turn a drawio-exported static .svg into the animated
# "marching-ants" .flow.svg used in the docs.
#
# The .flow.svg is just the static export plus (1) a tiny <style> block defining a
# `dio-flow` class that animates stroke-dashoffset, and (2) that class added to every
# connector-edge <path> (drawio marks edges with pointer-events="stroke"; lane-band
# separators use pointer-events="all" and are left un-animated). Regenerate it after
# any diagram edit so the animated version matches the static one.
#
# Usage: scripts/render-flow-svg.sh docs/diagrams/<name>.drawio
#   -> writes <name>.svg (static export) and <name>.flow.svg (animated) beside it.
# Requires the drawio CLI (brew install drawio).
set -uo pipefail
SRC="${1:?usage: render-flow-svg.sh <diagram.drawio>}"
[ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }
DRAWIO="${DRAWIO:-drawio}"
command -v "$DRAWIO" >/dev/null || { echo "drawio CLI not found (brew install drawio)" >&2; exit 1; }

base="${SRC%.drawio}"
svg="${base}.svg"
flow="${base}.flow.svg"

# 1. Export the static SVG from the drawio source.
"$DRAWIO" -x -f svg --no-sandbox -o "$svg" "$SRC" >/dev/null 2>&1 \
  || { echo "drawio export failed for $SRC" >&2; exit 1; }
[ -s "$svg" ] || { echo "export produced no output: $svg" >&2; exit 1; }

# 2. Build the animated flow.svg: inject the <style> right after the opening <svg …>,
#    and add class="dio-flow" to every connector-edge <path> (drawio marks edges with
#    pointer-events="stroke"; lane separators use pointer-events="all"). drawio exports
#    the whole SVG on ONE line, so operate on the full content (perl), not line-by-line.
STYLE='<style>.dio-flow{stroke-dasharray:6 4;animation:dio-flow 1.2s linear infinite;}@keyframes dio-flow{to{stroke-dashoffset:-10;}}</style>'
perl -0777 -pe '
  BEGIN { $style = shift @ARGV; }
  # inject the style once, right after the opening <svg ...> tag
  s/(<svg\b[^>]*>)/$1$style/ unless /dio-flow\{/;
  # add class="dio-flow" to every <path ...> that carries pointer-events="stroke"
  # and does not already have the class. Handle both: an existing class="…", or none.
  s{(<path\b(?![^>]*\bclass="dio-flow\b)[^>]*\bpointer-events="stroke"[^>]*>)}{
    my $p = $1;
    if ($p =~ /\bclass="/) { $p =~ s/\bclass="/class="dio-flow /; }
    else                   { $p =~ s/<path\b/<path class="dio-flow"/; }
    $p;
  }ge;
' "$STYLE" "$svg" > "$flow"
[ -s "$flow" ] || { echo "flow.svg generation produced no output" >&2; exit 1; }

# grep -c counts matching LINES; drawio SVG is one line, so count matches with -o|wc.
n="$(grep -o 'class="dio-flow"' "$flow" 2>/dev/null | wc -l | tr -d ' ')"
echo "wrote $svg and $flow (animated ${n:-0} edges)" >&2

#!/bin/sh
# Retired with the `dat/og` layer it compared: kept as the old name of
# scripts/convert-regress.sh, the guard now. Same arguments and $GORKY_TOOL, $JOBS, $KEEP:
# $KEEP gets the Classic battle logs (`<level>.<seed>.log`, compare two builds with diff -r),
# each also compared with the converted project's.
#
#   scripts/rules-regress.sh <game dir> [seeds…]     (default seeds 1 7 42)
exec sh "$(dirname "$0")/convert-regress.sh" "$@"

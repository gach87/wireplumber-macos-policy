#!/bin/sh
# WirePlumber .conf files are SPA-JSON and there is no standalone validator.
# At least check the delimiters balance: a malformed file stops WirePlumber
# from starting, and you lose audio.
set -e
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
status=0
for f in "$HERE"/../src/config/*.conf; do
    python3 -c '
import sys
p = sys.argv[1]
s = open(p).read()
for a, b in (("{", "}"), ("[", "]")):
    if s.count(a) != s.count(b):
        sys.exit("%s: %s%s unbalanced (%d vs %d)"
                 % (p, a, b, s.count(a), s.count(b)))
print("  ok   %s" % p.split("/")[-1])
' "$f" || status=1
done
exit $status

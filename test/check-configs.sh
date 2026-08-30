#!/bin/sh
# Los .conf de WirePlumber son SPA-JSON y no hay validador independiente.
# Al menos se comprueba que los delimitadores esten balanceados: un archivo mal
# formado impide que WirePlumber arranque, y te quedas sin audio.
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
        sys.exit("%s: %s%s desbalanceados (%d vs %d)"
                 % (p, a, b, s.count(a), s.count(b)))
print("  ok   %s" % p.split("/")[-1])
' "$f" || status=1
done
exit $status

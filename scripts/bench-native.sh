#!/usr/bin/env bash
# Times the native bb CLI on the witness written by `npm run bench` (sdk).
set -euo pipefail
cd "$(dirname "$0")/../circuits"
RUNS="${RUNS:-10}"
NARGO="${NARGO:-$HOME/.nargo/bin/nargo}"
BB="${BB:-$HOME/.bb/bb}"
OUT="$(mktemp -d)"

"$NARGO" execute witness >/dev/null
echo "gates:"; "$BB" gates -b target/zkmandate.json 2>/dev/null | grep -E 'acir_opcodes|circuit_size'

"$BB" write_vk -b target/zkmandate.json -o "$OUT" -t evm >/dev/null 2>&1
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
times=()
for i in $(seq 1 "$RUNS"); do
  t0=$(ms); "$BB" prove -b target/zkmandate.json -w target/witness.gz -k "$OUT/vk" -o "$OUT" -t evm >/dev/null 2>&1; t1=$(ms)
  times+=($((t1 - t0)))
done
vt0=$(ms); "$BB" verify -k "$OUT/vk" -p "$OUT/proof" -i "$OUT/public_inputs" -t evm >/dev/null 2>&1; vt1=$(ms)
echo "native bb prove (ms, wall, incl. process start): ${times[*]}"
printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END {m=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; print "median", m, "min", a[1], "max", a[NR]}'
echo "native bb verify (ms): $((vt1 - vt0))"
echo "proof bytes: $(wc -c < "$OUT/proof" | tr -d ' ')  public_inputs bytes: $(wc -c < "$OUT/public_inputs" | tr -d ' ')"
rm -rf "$OUT"

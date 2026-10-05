#!/usr/bin/env bash
# Regenerate all committed evidence after the RULEn rename, so logs
# and paper quotes match: four fault campaigns, the qv2 validation
# battery (determinism + faults + drift), and a clean run per backend
# to restore top-level logs.
set -u
set -o pipefail
cd "$(dirname "$0")"
fail=0

echo "=== campaign: renode ==="
BACKEND=renode bash run_faults.sh | tail -8 || fail=1
echo "=== campaign: qemu ==="
BACKEND=qemu bash run_faults.sh | tail -8 || fail=1
echo "=== campaign: v2 ==="
BACKEND=v2 bash run_faults.sh | tail -8 || fail=1
echo "=== validate qv2 (determinism + faults + drift) ==="
bash validate_qv2.sh | tail -8 || fail=1

echo "=== clean restores ==="
bash run_cosim.sh        | tail -2 || fail=1
bash run_cosim_qemu.sh   | tail -2 || fail=1
bash run_cosim_v2.sh     | tail -2 || fail=1
bash run_cosim_qv2.sh    | tail -2 || fail=1
bash run_cosim_spi.sh    | tail -2 || fail=1
bash run_cosim_i2cdrv.sh | tail -2 || fail=1

if [ $fail -eq 0 ]; then echo "REGEN: PASS"; else echo "REGEN: FAIL"; exit 1; fi

#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
pkill -f 'qemu-system-arm' 2>/dev/null || true
pkill -f 'xezim --simulate' 2>/dev/null || true
sleep 1
bash validate_qv2.sh 2>&1 | tee ../logs_qv2/validate.log \
  | grep -E 'DETERMINISM|harness finish|FAULT-CAMPAIGN|DRIFT-SWEEP|VALIDATE'

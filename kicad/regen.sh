#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
python3 gen_sch.py
bash verify_sch.sh 2>&1 | grep -E 'ERC:|NETLIST|FAB-SIM'
bash export_pdf.sh

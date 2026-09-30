#!/usr/bin/env bash
# Run both SPICE decks in batch mode; all output lands in
# ../logs_ngspice/ (ngspice.log, sweep_load.dat, tran_trip.dat).
set -eu
cd "$(dirname "$0")"
NG=${NG:-$HOME/ngspice-install/bin/ngspice}

{
  echo "==== bms_op.cir (operating points + load sweep) ===="
  "$NG" -b bms_op.cir
  echo
  echo "==== bms_trip.cir (transient DSG trip at 5 ms) ===="
  "$NG" -b bms_trip.cir
} > ../logs_ngspice/ngspice.log 2>&1

echo "ngspice done; log tail:"
tail -5 ../logs_ngspice/ngspice.log

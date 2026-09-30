#!/usr/bin/env bash
# Fetch the official KiCad symbol libraries (release tag 9.0.0,
# classic monolithic format) that the fabrication schematic's embedded
# symbols are taken from.  libs/ is gitignored; this script is the
# provenance.
set -u
cd "$(dirname "$0")/libs"
TAG=9.0.0
for f in Battery_Management MCU_ST_STM32G0 Device Connector_Generic power; do
  if curl -sfL --max-time 120 -o "$f.kicad_sym" \
    "https://gitlab.com/kicad/libraries/kicad-symbols/-/raw/$TAG/$f.kicad_sym"; then
    echo "OK   $f  ($(wc -c < "$f.kicad_sym") bytes)"
  else
    echo "MISS $f"
  fi
done

#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/libs"
echo "--- BQ769xx in Battery_Management ---"
grep -oE '\(symbol "BQ[0-9A-Za-z_]+"' Battery_Management.kicad_sym | sort -u | grep 769 || echo none
echo "--- STM32G0B1 flavours ---"
grep -oE '\(symbol "STM32G0B1[0-9A-Za-z_]+"' MCU_ST_STM32G0.kicad_sym | sort -u
echo "--- generic parts present? ---"
for s in '(symbol "R"' '(symbol "C"' '(symbol "Thermistor_NTC"' '(symbol "Battery_Cell"' '(symbol "Q_NMOS_GSD"' '(symbol "D_Schottky"' '(symbol "Polyfuse"'; do
  grep -cF "$s" Device.kicad_sym | xargs echo "$s ->"
done
for s in '(symbol "Conn_01x02"' '(symbol "Conn_01x05"' '(symbol "Conn_01x07"'; do
  grep -cF "$s" Connector_Generic.kicad_sym | xargs echo "$s ->"
done
for s in '(symbol "GND"' '(symbol "+3V3"' '(symbol "PWR_FLAG"'; do
  grep -cF "$s" power.kicad_sym | xargs echo "$s ->"
done

#!/usr/bin/env bash
# Fetch and build Accellera SystemC 2.3.4 (IEEE 1666-2011, includes
# TLM-2.0) into ~/systemc.  Autotools release tarball: needs only
# gcc/g++/make, no sudo, no cmake.
set -eu
if [ -f "$HOME/systemc/lib-linux64/libsystemc.a" ] || \
   [ -f "$HOME/systemc/lib/libsystemc.a" ]; then
  echo "SYSTEMC-DONE (already installed)"
  exit 0
fi
cd /tmp
url="https://github.com/accellera-official/systemc/archive/refs/tags/2.3.4.tar.gz"
echo "url: $url"
curl -sL "$url" -o systemc.tar.gz
rm -rf systemc-src && mkdir systemc-src
tar xzf systemc.tar.gz -C systemc-src --strip-components=1
# the tag archive lacks automake's Makefile.in files; use the CMake
# flow.  No sudo, no venv (ensurepip missing): bootstrap pip --user.
export PATH="$HOME/.local/bin:$PATH"
if ! command -v cmake >/dev/null 2>&1; then
  if ! python3 -m pip --version >/dev/null 2>&1; then
    curl -sL https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    python3 get-pip.py --user --break-system-packages -q
  fi
  python3 -m pip install --user --break-system-packages -q cmake ninja
fi
command -v cmake
command -v ninja
cmake -S systemc-src -B systemc-build -G Ninja \
  -DCMAKE_INSTALL_PREFIX="$HOME/systemc" \
  -DCMAKE_CXX_STANDARD=17 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  > cmake.log 2>&1 || { tail -20 cmake.log; exit 1; }
cmake --build systemc-build > build.log 2>&1 || { tail -20 build.log; exit 1; }
cmake --install systemc-build > install.log 2>&1
ls "$HOME/systemc"
echo "SYSTEMC-DONE"

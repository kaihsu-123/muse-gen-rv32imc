#!/bin/bash
# Environment for the RV32IMC OpenROAD flow.
# Source this before running anything:  source ~/workspace/rv32imc-cpu/pnr/env.sh
CPU_TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RV32IMC_TOP="$CPU_TOP"
export PATH="$CPU_TOP/tools/oss-cad-suite/bin:$CPU_TOP/tools/openroad24/usr/bin:$CPU_TOP/pnr/venv/bin:$PATH"
export LD_LIBRARY_PATH="$CPU_TOP/tools/sysroot/usr/lib/x86_64-linux-gnu:$CPU_TOP/tools/ortools914/or-tools_x86_64_Ubuntu-24.04_cpp_v9.14.6206/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export OPENROAD_EXE="$CPU_TOP/pnr/bin/openroad"
export YOSYS_EXE="$CPU_TOP/tools/oss-cad-suite/bin/yosys"
export PDK_ROOT="$CPU_TOP/pdk/volare"
# volare http_proxy workaround (httpx chokes on IPv6 literals in NO_PROXY)
export no_proxy="localhost,127.0.0.1"
export NO_PROXY="localhost,127.0.0.1"
echo "RV32IMC P&R env ready: $CPU_TOP"

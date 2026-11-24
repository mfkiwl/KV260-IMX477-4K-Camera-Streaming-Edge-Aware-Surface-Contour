#!/bin/sh
set -eu
# Usage: sh synthesize.sh PROJECT_DIRECTORY OUTPUT_DIRECTORY
project=$(cd "$1" && pwd)
mkdir -p "$2"
cd "$2"
set --
while IFS= read -r file || test -n "$file"; do
    test -z "$file" || set -- "$@" "$project/rtl/$file"
done < "$project/rtl/files.f"
ghdl -a --std=08 "$@"
ghdl synth --std=08 --out=verilog -gG_WIDTH=2048 -gG_HEIGHT=1152 axis_portrait_filter > axis_portrait_filter.v

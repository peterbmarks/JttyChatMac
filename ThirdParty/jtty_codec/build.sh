#!/bin/sh
# Rebuilds lib/libjttycodec.a from the Fortran sources in this directory.
#
# These sources are unmodified (see NOTICE.txt / COPYING) and have no
# Xcode build rule, so Xcode can't compile them itself; run this script
# whenever a source changes, or after cloning on a new machine. Requires
# Homebrew's gfortran (`brew install gcc`).
#
# Fortran module dependencies mean files must be compiled in dependency
# order; rather than hard-code that order, this retries failed files
# across multiple passes until every file has compiled (a fixed-point
# compile), which is robust to reordering/adding files.
set -e
cd "$(dirname "$0")"

rm -f ./*.o ./*.mod lib/libjttycodec.a
remaining=$(ls ./*.f90)
pass=0
while [ -n "$remaining" ]; do
    pass=$((pass + 1))
    if [ "$pass" -gt 10 ]; then
        echo "error: too many passes, giving up" >&2
        exit 1
    fi
    next=""
    progress=0
    for f in $remaining; do
        obj="${f%.f90}.o"
        if gfortran -c -O2 -std=legacy -ffree-form -fno-second-underscore -mmacosx-version-min=27.0 \
            -I/opt/homebrew/include "$f" -o "$obj" 2>/tmp/jttycodec-build.log; then
            progress=1
        else
            next="$next $f"
        fi
    done
    remaining=$next
    if [ "$progress" -eq 0 ]; then
        echo "error: no progress compiling: $remaining" >&2
        cat /tmp/jttycodec-build.log >&2
        exit 1
    fi
done

mkdir -p lib
ar rcs lib/libjttycodec.a ./*.o
ranlib lib/libjttycodec.a
rm -f ./*.o ./*.mod
echo "Built lib/libjttycodec.a"

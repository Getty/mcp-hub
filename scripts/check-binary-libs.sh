#!/usr/bin/env bash
# The library gate: the packed mcp-hub needs no shared library outside the system
# allowlist below, and (Linux) no glibc above GLIBC_MAX.
#   scripts/check-binary-libs.sh <binary>
#
# It runs the binary once into its own PAR_GLOBAL_TMPDIR and inspects what PAR
# unpacked there -- the archive (every XS object) and libperl, which the loader
# carries outside the zip, so unzipping the binary alone would miss libperl's needs.
#
# A dev-box build with the distribution's perl FAILS here, as it should: a stock
# Debian/Ubuntu libperl needs libcrypt.so.1, which Rocky/Alma 9 and Fedora do not
# ship, and the host's glibc is newer than the floor. A release binary is packed with
# a perl built without crypt() on an old-glibc base (the mcp-wiki spike, dzil-binary).
set -euo pipefail

case "$(uname -s)" in
  Darwin)
    TOOL=otool ;;
  *)
    TOOL=ldd
    # Part of glibc on every distribution; libperl is shipped inside the binary.
    ALLOW='linux-vdso|ld-linux-.*|libc|libm|libpthread|libdl|librt|libutil|libperl'
    # The glibc floor the README promises: the highest GLIBC_x.y symbol version any
    # object may need. 2.28 is the AlmaLinux 8 / manylinux_2_28 build base of the
    # binary release design; override for another base.
    GLIBC_MAX=${MCP_HUB_GLIBC_MAX:-2.28} ;;
esac

BIN=${1:?usage: check-binary-libs.sh <binary>}
case "$BIN" in /*) ;; *) BIN="$PWD/$BIN" ;; esac
[ -x "$BIN" ] || { echo "FAIL: not an executable: $BIN" >&2; exit 1; }
command -v "$TOOL" >/dev/null 2>&1 || { echo "FAIL: $TOOL is not installed" >&2; exit 1; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/par" "$work/home"

env -i PATH=/usr/bin:/bin HOME="$work/home" PAR_GLOBAL_TMPDIR="$work/par" "$BIN" token >/dev/null 2>"$work/run.err" \
  || { echo "FAIL: the binary does not start: $(head -n 5 "$work/run.err")" >&2; exit 1; }
objects=("$BIN")
while IFS= read -r f; do objects+=("$f"); done \
  < <(find "$work/par" -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.bundle' -o -name '*.dylib' \) | sort)
[ "${#objects[@]}" -ge 3 ] || { echo "FAIL: nothing unpacked below $work/par (${#objects[@]} objects)" >&2; exit 1; }

# One "lib<TAB>object" line per need.
: >"$work/needs"
for obj in "${objects[@]}"; do
  short=${obj#"$work/par/"}; short=${short#par-*/cache-*/}
  if [ "$TOOL" = ldd ]; then
    if ! ldd "$obj" >"$work/out" 2>&1; then
      grep -q 'not a dynamic executable' "$work/out" && continue
      echo "FAIL: ldd $short: $(cat "$work/out")" >&2; exit 1
    fi
    if grep -q 'not found' "$work/out"; then echo "FAIL: $short: $(grep 'not found' "$work/out")" >&2; exit 1; fi
    awk '$1 ~ /\.so/ { l = $1; sub(/.*\//, "", l); sub(/\.so.*/, "", l); print l }' "$work/out" >"$work/libs"
  else
    # macOS: everything outside /usr/lib and /System is a non-system library. A dylib
    # lists its own install name (otool -D) first, which is not a need.
    id=$(otool -D "$obj" 2>/dev/null | sed -n 2p)
    { otool -L "$obj" | tail -n +2 | awk '{print $1}' | grep -vxF "${id:-//none//}" \
        | grep -v -e '^/usr/lib/' -e '^/System/' || true; } >"$work/libs"
  fi
  sort -u "$work/libs" | sed "s|\$|	$short|" >>"$work/needs"
done

echo "Shared libraries needed (${#objects[@]} objects):"
cut -f1 "$work/needs" | sort -u | sed 's/^/  /'
if [ "$TOOL" = ldd ]; then
  bad=$(cut -f1 "$work/needs" | sort -u | grep -vxE "$ALLOW" || true)
else
  bad=$(cut -f1 "$work/needs" | sort -u)
fi
rc=0
for lib in $bad; do
  echo "FAIL: non-system library $lib, needed by: $(awk -F'\t' -v l="$lib" '$1 == l {print $2}' "$work/needs" | paste -sd' ' -)" >&2
  rc=1
done
[ "$rc" = 0 ] && echo "library allowlist: OK"

if [ "$TOOL" = ldd ]; then
  command -v objdump >/dev/null 2>&1 || { echo "FAIL: objdump is not installed (binutils)" >&2; exit 1; }
  for obj in "${objects[@]}"; do
    objdump -T "$obj" 2>/dev/null | awk '/\*UND\*/' | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' \
      | sed "s|\$|	${obj##*/}|" || true
  done | sort -u >"$work/glibc"
  floor=$(cut -f1 "$work/glibc" | sort -uV | tail -n 1)
  [ -n "$floor" ] || { echo "FAIL: no GLIBC_ symbol versions found" >&2; exit 1; }
  if [ "$(printf '%s\n%s\n' "$floor" "$GLIBC_MAX" | sort -V | tail -n 1)" = "$GLIBC_MAX" ]; then
    echo "glibc floor: $floor (allowed: $GLIBC_MAX): OK"
  else
    echo "FAIL: needs glibc $floor, above $GLIBC_MAX, by: $(awk -F'\t' -v f="$floor" '$1 == f {print $2}' "$work/glibc" | sort -u | paste -sd' ' -)" >&2
    rc=1
  fi
fi
[ "$rc" = 0 ] && echo "libs: OK"
exit "$rc"

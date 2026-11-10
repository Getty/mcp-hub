#!/usr/bin/env bash
# TLS for a portable mcp-hub binary: build OpenSSL as static libraries and install
# Net::SSLeay (linked against them), IO::Socket::SSL and Mozilla::CA into the perl on
# PATH. binary_prepare of the [@Author::GETTY] bundle (dist.ini): its dzil-binary
# workflow runs it from the dist root once per platform, after the packing perl and
# before the dist's dependencies are installed -- a Net::SSLeay that cpanm builds first
# links the host's libssl instead -- with the deps local lib active and the cache dir
# it keeps per platform (keyed by this file's checksum) as PREFIX.
#   scripts/binary-prepare.sh PREFIX
# PREFIX receives OpenSSL (bin/openssl, lib/libssl.a, lib/libcrypto.a, include/) and
# is reused when it already holds this version. cpanm installs where it always does
# for this perl (PERL_CPANM_OPT, -L, local::lib). Needs curl, a C compiler and make.
# Exit 0 when the perl on PATH has Net::SSLeay on this OpenSSL, non-zero otherwise.
#
# Why static: the binary must not depend on the target's OpenSSL. Linux distributions
# ship different sonames (libssl.so.1.1, libssl.so.3) or none in a minimal image,
# macOS ships no OpenSSL at all, and the bundle's library gate admits system libraries only.
#
# The trust store: IO::Socket::SSL looks for the host's CA certificates in
# $SSL_CERT_DIR or OPENSSLDIR/certs (a hashed directory) and in $SSL_CERT_FILE or
# OPENSSLDIR/cert.pem, and falls back to Mozilla::CA's bundle when it finds neither.
# OPENSSLDIR=/etc/ssl hits the system store on Debian/Ubuntu (/etc/ssl/certs), RHEL 9+
# and Fedora (/etc/ssl/cert.pem) and macOS (/etc/ssl/cert.pem); the RHEL 8 family and
# images without ca-certificates get the packed Mozilla bundle.
# no-autoload-config: OPENSSLDIR/openssl.cnf on the target belongs to the system's own
# OpenSSL (RHEL's pulls in crypto-policies, FIPS includes) -- this one never reads it.
set -euo pipefail

# OpenSSL 3.5 is the LTS line, supported until 2030-04-08. Bump the patch release
# with each security release: https://openssl-library.org/news/vulnerabilities/
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"

PREFIX=${1:?usage: binary-prepare.sh PREFIX}
mkdir -p "$PREFIX"; PREFIX=$(cd "$PREFIX" && pwd)
command -v cpanm >/dev/null 2>&1 || { echo "ERROR: cpanm is not installed" >&2; exit 1; }
want="OpenSSL $OPENSSL_VERSION "

if [ -x "$PREFIX/bin/openssl" ] && "$PREFIX/bin/openssl" version | grep -q "^$want"; then
  echo "OpenSSL $OPENSSL_VERSION already in $PREFIX"
else
  work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
  curl -sSfL -o "$work/openssl.tar.gz" "$OPENSSL_URL"
  if command -v sha256sum >/dev/null 2>&1; then sum=$(sha256sum "$work/openssl.tar.gz")
  else sum=$(shasum -a 256 "$work/openssl.tar.gz"); fi
  [ "${sum%% *}" = "$OPENSSL_SHA256" ] \
    || { echo "ERROR: openssl-$OPENSSL_VERSION.tar.gz: sha256 ${sum%% *}, want $OPENSSL_SHA256" >&2; exit 1; }
  tar xzf "$work/openssl.tar.gz" -C "$work"
  jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
  # no-shared: libssl.a/libcrypto.a only, so Net::SSLeay cannot pick a shared one;
  #   -fPIC because they end up inside Net::SSLeay's shared object.
  # no-module: providers built in, nothing dlopen()ed from a MODULESDIR at run time.
  # --libdir=lib: never lib64, where Net::SSLeay does not look.
  ( cd "$work/openssl-$OPENSSL_VERSION" \
    && ./Configure --prefix="$PREFIX" --libdir=lib --openssldir=/etc/ssl \
         no-shared no-module no-autoload-config no-tests no-docs -fPIC >"$work/configure.log" 2>&1 \
    && make -j"$jobs" >"$work/make.log" 2>&1 \
    && make install_sw >"$work/install.log" 2>&1 ) \
    || { tail -n 40 "$work"/*.log >&2; echo "ERROR: OpenSSL $OPENSSL_VERSION did not build" >&2; exit 1; }
  "$PREFIX/bin/openssl" version | grep -q "^$want" || { echo "ERROR: $PREFIX/bin/openssl is not $OPENSSL_VERSION" >&2; exit 1; }
  echo "OpenSSL $OPENSSL_VERSION built into $PREFIX"
fi

# Net::SSLeay's Makefile.PL takes OpenSSL from OPENSSL_PREFIX and finds only the
# static libraries there. It also links -lz unconditionally, which this OpenSSL does
# not use: that fails without zlib's development files and, with them, makes the
# binary need libz.so.1. LIBS via PERL_MM_OPT replaces its link list (the MakeMaker
# way to override it). --reinstall: a Net::SSLeay already installed may link another
# OpenSSL. PERL_MM_USE_DEFAULT answers its prompt for network tests (no).
OPENSSL_PREFIX="$PREFIX" PERL_MM_USE_DEFAULT=1 \
  PERL_MM_OPT="${PERL_MM_OPT:+$PERL_MM_OPT }LIBS='-L$PREFIX/lib -lssl -lcrypto'" \
  cpanm --reinstall Net::SSLeay
cpanm IO::Socket::SSL Mozilla::CA

# The result must say so: this OpenSSL, OPENSSLDIR /etc/ssl, and no libssl/libcrypto
# needed from the system by Net::SSLeay's shared object.
perl -MNet::SSLeay -e 'print Net::SSLeay::SSLeay_version(0), "\n", Net::SSLeay::SSLeay_version(4), "\n"' >"$PREFIX/.check"
grep -q "^$want" "$PREFIX/.check" || { echo "ERROR: Net::SSLeay reports $(head -n 1 "$PREFIX/.check")" >&2; exit 1; }
grep -qx 'OPENSSLDIR: "/etc/ssl"' "$PREFIX/.check" || { echo "ERROR: Net::SSLeay reports $(sed -n 2p "$PREFIX/.check")" >&2; exit 1; }
so=$(perl -MNet::SSLeay -e 'print grep { m{/SSLeay\.(?:so|bundle)\z} } @DynaLoader::dl_shared_objects')
[ -f "$so" ] || { echo "ERROR: cannot find Net::SSLeay's shared object" >&2; exit 1; }
if [ "$(uname -s)" = Darwin ]; then needs=$(otool -L "$so" | tail -n +2); else needs=$(ldd "$so"); fi
if grep -E 'lib(ssl|crypto|z)\.' <<<"$needs" >/dev/null; then
  echo "ERROR: $so links OpenSSL or zlib dynamically:" >&2; echo "$needs" >&2; exit 1
fi
perl -MIO::Socket::SSL=2.009 -MMozilla::CA -e 'print "IO::Socket::SSL $IO::Socket::SSL::VERSION, Mozilla::CA $Mozilla::CA::VERSION\n"'
echo "TLS for the binary: $(head -n 1 "$PREFIX/.check"), static in $so"

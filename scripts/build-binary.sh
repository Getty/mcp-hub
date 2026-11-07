#!/usr/bin/env bash
# Pack bin/mcp-hub into one standalone executable with PAR::Packer, with the perl
# on PATH. Run from the checkout root. Output: $MCP_HUB_BIN_OUT (default ./mcp-hub).
#
# This is the local build. Release binaries come from the [@Author::GETTY] bundle's
# binary release form (dzil-binary), which packs with its own portable perl and needs
# what this script passes to pp: the -M set, the -X set, the Mojolicious resources
# and PAR_VERBATIM=1 -- and, in that perl, what the guards below require.
#
# pp exits 0 on a binary that only dies at run time; scripts/verify-binary.sh and
# scripts/smoke-binary.sh are what prove a build.
set -euo pipefail

OUT="${MCP_HUB_BIN_OUT:-./mcp-hub}"
[ -f bin/mcp-hub ] && [ -f lib/MCP/Hub.pm ] || { echo "ERROR: run from the checkout root" >&2; exit 1; }
command -v pp >/dev/null 2>&1 || { echo "ERROR: pp (PAR::Packer) is not installed" >&2; exit 1; }

# Every module needed at run time must be installed, or the loaded set below is short.
# YAML::PP is loaded on demand only, so a missing one would not show anywhere else.
perl -Ilib -MMCP::Hub -MYAML::PP -e1 \
  || { echo "ERROR: runtime dependencies missing (cpanm --installdeps .)" >&2; exit 1; }
# TLS: IO::Socket::SSL on Net::SSLeay, and Mozilla::CA as the trust store of last
# resort. Net::SSLeay carries whatever OpenSSL it was built against into the binary:
# a portable build links OpenSSL statically (scripts/build-binary-openssl.sh), a
# dev-box build links the host's libssl, which check-binary-libs.sh then rejects.
perl -MIO::Socket::SSL=2.009 -MMozilla::CA -e1 \
  || { echo "ERROR: TLS modules missing (scripts/build-binary-openssl.sh, or cpanm IO::Socket::SSL Mozilla::CA)" >&2; exit 1; }
# JSON in C: Mojo::JSON (4.20+) and JSON::MaybeXS, the natives' decoder, each load
# Cpanel::JSON::XS by name and fall back to pure Perl without it -- dozens of times
# slower on a large Claude Code history. JSON::MaybeXS installs it wherever its own
# install finds a C compiler; a perl that got JSON::MaybeXS without one lacks it.
env -u MOJO_NO_JSON_XS perl -MMojo::JSON -MJSON::MaybeXS \
  -e 'exit !(Mojo::JSON::JSON_XS && JSON::MaybeXS::JSON() eq "Cpanel::JSON::XS")' \
  || { echo "ERROR: Cpanel::JSON::XS 4.20+ missing: the binary would decode JSON in pure Perl (cpanm Cpanel::JSON::XS)" >&2; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# The loaded set: scripts/loaded-modules.pl runs every command and a daemon round trip
# and prints every module that came from its own file -- what pp's scanner cannot see
# included: the commands Mojolicious finds by namespace (MCP::Hub::Command::*,
# Mojolicious::Command::*), the natives Upstream::Perl mounts by `class`, YAML::PP and
# the schema it loads by name, Mojolicious' plugins and reactor, and Cpanel::JSON::XS
# (pp packs its shared object with it). It dies when the round trip fails or JSON
# would decode in pure Perl. verify-binary.sh requires the same list inside the archive.
perl -Ilib scripts/loaded-modules.pl >"$work/loaded" \
  || { echo "ERROR: scripts/loaded-modules.pl failed" >&2; exit 1; }
loaded=(); while IFS= read -r m; do loaded+=("$m"); done <"$work/loaded"
[ "${#loaded[@]}" -gt 150 ] || { echo "ERROR: loaded set suspiciously small (${#loaded[@]})" >&2; exit 1; }
mods=(); for m in "${loaded[@]}"; do mods+=(-M "$m"); done

# Left out of every build (the list and the reasons: scripts/loaded-modules.pl
# --left-out): EV, the optional Mojolicious extras, JSON.pm, and what IO::Socket::SSL
# would drag in -- LWP, URI and the IDN libraries. `pp -X Name` drops exactly Name.pm,
# has no wildcard, and the scanner still follows `require Name` into the module's own
# dependencies. So a "Name::" entry takes one -X per module of that namespace found in
# @INC on this host. Every binary then has the same features on every platform;
# verify-binary.sh rejects any of them in the archive.
perl scripts/loaded-modules.pl --left-out >"$work/left-out"
noopt=()
while IFS= read -r m; do noopt+=(-X "$m"); done < <(perl -MFile::Find -e '
  my %m;
  for my $spec (@ARGV) {
    if ($spec !~ /::\z/) { $m{$spec} = 1; next }
    (my $path = $spec) =~ s{::\z}{};
    $path =~ s{::}{/}g;
    for my $dir (grep { !ref } @INC) {
      next unless -d "$dir/$path";
      File::Find::find({ no_chdir => 1, wanted => sub {
        return unless /\.pm\z/;
        (my $n = substr $_, length($dir) + 1) =~ s{/}{::}g;
        $n =~ s/\.pm\z//;
        $m{$n} = 1;
      } }, "$dir/$path");
    }
  }
  print "$_\n" for sort keys %m;' $(cat "$work/left-out"))

# Mojolicious reads its bundled templates and static files from the directory next to
# Mojolicious/Renderer.pm and Mojolicious/Static.pm (curfile->sibling('resources')):
# the not_found and exception pages (mojo/debug in development mode, the default) and
# their /mojo/*.css|js. pp packs no data files of its own accord; without this a 404
# for a browser renders nothing. (Mojo/resources/html_entities.txt is packed by
# Module::ScanDeps itself.)
mojo_lib=$(perl -MMojolicious -e 'print $INC{"Mojolicious.pm"} =~ s{/Mojolicious\.pm\z}{}r')
[ -d "$mojo_lib/Mojolicious/resources/templates" ] \
  || { echo "ERROR: no Mojolicious/resources below $mojo_lib" >&2; exit 1; }

# PAR_VERBATIM=1: pp's POD-stripping filter corrupts files whose POD sits between code
#   (=attr/=method under [@Author::GETTY]) until a module "did not return a true value".
# -I lib: the checkout's lib/ wins over any installed copy.
PAR_VERBATIM=1 pp -o "$OUT" \
  -I lib \
  "${mods[@]}" \
  "${noopt[@]}" \
  -a "$mojo_lib/Mojolicious/resources;lib/Mojolicious/resources" \
  bin/mcp-hub

chmod +x "$OUT"
echo "Built $OUT ($(du -h "$OUT" | cut -f1), ${#loaded[@]} modules, ${#noopt[@]} left out," \
  "$(perl -MNet::SSLeay -e 'print Net::SSLeay::SSLeay_version(0)'))"

#!/usr/bin/env bash
# The pp arguments of the mcp-hub binary, one per line on STDOUT: binary_pp_args of
# the [@Author::GETTY] bundle (dist.ini). Run from the dist root with the perl that
# packs; problems go to STDERR and end the run with exit 1, which fails the build.
#   scripts/binary-pp-args.sh
#
# The bundle runs pp itself -- locally after `dzil build`, and per platform in its
# dzil-binary workflow -- as  PAR_VERBATIM=1 pp -o OUT -I lib <these lines> bin/mcp-hub.
# PAR_VERBATIM=1 matters here: pp's POD-stripping filter corrupts files whose POD sits
# between code (=attr/=method under [@Author::GETTY]) until a module "did not return a
# true value". This script adds what pp cannot know: the -M set, the -X set and the
# Mojolicious resources.
#
# pp exits 0 on a binary that only dies at run time; scripts/binary-verify.sh and
# scripts/binary-smoke.sh are what prove a build.
set -euo pipefail

[ -f bin/mcp-hub ] && [ -f lib/MCP/Hub.pm ] || { echo "ERROR: run from the dist root" >&2; exit 1; }

# Every module needed at run time must be installed, or the loaded set below is short.
# YAML::PP is loaded on demand only, so a missing one would not show anywhere else.
perl -Ilib -MMCP::Hub -MYAML::PP -e1 \
  || { echo "ERROR: runtime dependencies missing (cpanm --installdeps .)" >&2; exit 1; }
# TLS: IO::Socket::SSL on Net::SSLeay, and Mozilla::CA as the trust store of last
# resort. Net::SSLeay carries whatever OpenSSL it was built against into the binary:
# a portable build links OpenSSL statically (scripts/binary-prepare.sh, binary_prepare),
# a dev-box build links the host's libssl, which the bundle's library gate rejects.
perl -MIO::Socket::SSL=2.009 -MMozilla::CA -e1 \
  || { echo "ERROR: TLS modules missing (scripts/binary-prepare.sh, or cpanm IO::Socket::SSL Mozilla::CA)" >&2; exit 1; }
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
# would decode in pure Perl. binary-verify.sh requires the same list inside the archive.
perl -Ilib scripts/loaded-modules.pl >"$work/loaded" \
  || { echo "ERROR: scripts/loaded-modules.pl failed" >&2; exit 1; }
loaded=(); while IFS= read -r m; do loaded+=("$m"); done <"$work/loaded"
[ "${#loaded[@]}" -gt 150 ] || { echo "ERROR: loaded set suspiciously small (${#loaded[@]})" >&2; exit 1; }

# Left out of every build (the list and the reasons: scripts/loaded-modules.pl
# --left-out): EV, the optional Mojolicious extras, JSON.pm, and what IO::Socket::SSL
# would drag in -- LWP, URI and the IDN libraries. `pp -X Name` drops exactly Name.pm,
# has no wildcard, and the scanner still follows `require Name` into the module's own
# dependencies. So a "Name::" entry takes one -X per module of that namespace found in
# @INC on this host. Every binary then has the same features on every platform;
# binary-verify.sh rejects any of them in the archive.
perl scripts/loaded-modules.pl --left-out >"$work/left-out"
noopt=()
while IFS= read -r m; do noopt+=("$m"); done < <(perl -MFile::Find -e '
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

# One argument per line, never word-split (the bundle's rule for binary_pp_args).
for m in "${loaded[@]}"; do printf -- '-M\n%s\n' "$m"; done
for m in ${noopt[@]+"${noopt[@]}"}; do printf -- '-X\n%s\n' "$m"; done
printf -- '-a\n%s\n' "$mojo_lib/Mojolicious/resources;lib/Mojolicious/resources"

echo "binary-pp-args: ${#loaded[@]} modules (-M), ${#noopt[@]} left out (-X), Mojolicious resources (-a);" \
  "$(perl -MNet::SSLeay -e 'print Net::SSLeay::SSLeay_version(0)')" >&2

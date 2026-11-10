#!/usr/bin/env perl
# The standalone binary is declared to the [@Author::GETTY] bundle: dist.ini
# keys, a caller workflow pinned to the bundle's reusable workflow, the binary
# scripts executable in git (and the pre-bundle script names gone), and CI that
# does not build the binary on every push. Reads repository files only; no
# network, nothing written. (t/binary.t pins the fixtures of the binary checks,
# not this wiring.)
#
# The release tarball may ship neither .github/ nor .git, so the checks that
# need them skip when that file is absent, never when it is present.
use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(path);

plan skip_all => 'dist.ini not found (run from the distribution root)'
  unless -f 'dist.ini';

# -- dist.ini declares the binary -------------------------------------------------
my $dist_ini = path('dist.ini')->slurp;
my %want     = (
  binary           => 'mcp-hub',
  binary_platforms => 'linux-x86_64 linux-arm64 macos-arm64',
  binary_pp_args   => 'scripts/binary-pp-args.sh',
  binary_prepare   => 'scripts/binary-prepare.sh',
  binary_verify    => 'scripts/binary-verify.sh',
  binary_smoke     => 'scripts/binary-smoke.sh',
);
for my $key (sort keys %want) {
  like $dist_ini, qr/^\Q$key\E[ \t]*=[ \t]*\Q$want{$key}\E[ \t]*$/m, "dist.ini: $key = $want{$key}";
}

# binary_require repeats; the names across all its lines are the set the
# workflow loads inside every binary.
my @required = map { split ' ', $_ } $dist_ini =~ /^binary_require[ \t]*=[ \t]*(.*?)[ \t]*$/mg;
my %seen;
$seen{$_}++ for @required;
my @want_required = qw(
  MCP::Hub::Command::config MCP::Hub::Command::daemon MCP::Hub::Command::refresh
  MCP::Hub::Command::reload MCP::Hub::Command::status MCP::Hub::Command::token
  Mojolicious::Command::eval Mojolicious::Command::get Mojolicious::Command::routes
  Mojolicious::Command::version
  MCP::Hub::Upstream::Stdio MCP::Hub::Upstream::Http MCP::Hub::Upstream::Perl
  MCP::Hub::Upstream::Fork MCP::Hub::Upstream::Docker MCP::Hub::Upstream::Compose
  MCP::Hub::Upstream::Docker::Engine MCP::Hub::Upstream::Docker::Http
  MCP::Hub::Upstream::Docker::Stdio
  MCP::Hub::Native::ClaudeHistory MCP::Hub::Native::ClaudeSessions MCP::Hub::Native::Status
  YAML::PP Mojo::Reactor::Poll Cpanel::JSON::XS IO::Socket::SSL Net::SSLeay Mozilla::CA
);
is scalar(@want_required), 28, 'the expected binary_require set is 28 names';
is_deeply [sort keys %seen], [sort @want_required], 'dist.ini: binary_require names are exactly the 28 expected';
is_deeply [grep { $seen{$_} > 1 } sort keys %seen], [], 'dist.ini: no binary_require name is listed twice';

# -- caller workflow --------------------------------------------------------------
SKIP: {
  skip '.github/ not shipped in the distribution', 2 unless -d '.github';
  my $wf = path('.github/workflows/binaries.yml');
  ok -f "$wf", 'binaries.yml exists';

  # The whole file is pinned: a partial pin lets broken callers (no tag
  # input, no permissions) pass.
  my $caller = <<'YAML';
name: binaries
on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      tag:
        description: Release tag to build and attach; empty = probe run
        required: false
jobs:
  binaries:
    permissions:
      contents: write
    uses: Getty/p5-dist-zilla-pluginbundle-author-getty/.github/workflows/dzil-binary.yml@binary-v1
    with:
      tag: ${{ github.event.release.tag_name || inputs.tag }}
YAML
  is((-f "$wf" ? $wf->slurp : ''), $caller, 'binaries.yml is the bundle caller workflow, verbatim');
}

# -- scripts tracked and executable, old names gone --------------------------------
SKIP: {
  skip 'not a git checkout', 4 unless -e '.git';
  my $git = do {
    my ($g) = grep { -x "$_/git" && !-d "$_/git" } split /:/, $ENV{PATH} // '';
    $g ? "$g/git" : undef;
  };
  skip 'git not available', 4 unless $git;
  my @new = qw(scripts/binary-pp-args.sh scripts/binary-prepare.sh scripts/binary-verify.sh
    scripts/binary-smoke.sh scripts/loaded-modules.pl);
  my @old = qw(scripts/build-binary.sh scripts/build-binary-openssl.sh scripts/smoke-binary.sh
    scripts/verify-binary.sh scripts/check-binary-libs.sh);

  my @lines = grep {length} split /\n/, scalar qx{$git ls-files -s -- @new 2>/dev/null};
  is scalar(@lines), scalar(@new), 'the five binary scripts are tracked';
  is scalar(grep {/^100755 /} @lines), scalar(@new), 'all of them mode 100755';

  my @old_lines = grep {length} split /\n/, scalar qx{$git ls-files -- @old 2>/dev/null};
  is_deeply \@old_lines, [], 'the pre-bundle script names are not tracked (check-binary-libs.sh is the bundle\'s lib-gate.pl now)';
  ok !(grep { -e $_ } @old), 'and not in the working tree';
}

# -- CI does not build the binary on every push -------------------------------------
SKIP: {
  skip 'ci.yml not shipped in the distribution', 1 unless -d '.github';
  my $ci = path('.github/workflows/ci.yml');
  like -f "$ci" ? $ci->slurp : '', qr/^\s*DZIL_BINARY_SKIP:\s*['"]?1['"]?\s*$/m, 'ci.yml sets DZIL_BINARY_SKIP: 1';
}

done_testing;

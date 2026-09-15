use Mojo::Base -strict;
use Test::More;
use Mojo::File qw(tempdir);
use MCP::Hub::Manifest;

my $dir = tempdir;
my $m   = MCP::Hub::Manifest->new(cache_dir => "$dir");

subtest 'hash is stable and ignores env' => sub {
  my $h1 = $m->hash('npx', ['-y', 'ctx'], '/work');
  my $h2 = $m->hash('npx', ['-y', 'ctx'], '/work');
  is $h1, $h2, 'same input -> same hash';
  is length($h1), 16, '16 hex chars';

  my $h3 = $m->hash('npx', ['-y', 'other'], '/work');
  isnt $h1, $h3, 'different args -> different hash';
};

subtest 'round-trip' => sub {
  my $hash = $m->hash('npx', ['ctx']);
  ok !$m->fresh('context7', $hash), 'not fresh before write';
  is $m->load('context7', $hash), undef, 'load misses before write';

  my $manifest = {
    name  => 'context7',
    hash  => $hash,
    tools => [{name => 'resolve', description => 'x', inputSchema => {type => 'object'}}],
  };
  my $file = $m->store($manifest);
  ok -f $file, 'file written';
  like "$file", qr/context7-\Q$hash\E\.json$/, 'file naming';

  ok $m->fresh('context7', $hash), 'fresh after write';
  is_deeply $m->load('context7', $hash), $manifest, 'load returns what was stored';
};

subtest 'hash change means a miss' => sub {
  my $old = $m->hash('cmd', ['v1']);
  $m->store({name => 's', hash => $old, tools => []});
  my $new = $m->hash('cmd', ['v2']);
  ok $m->fresh('s', $old),  'old hash still fresh';
  ok !$m->fresh('s', $new), 'new hash not fresh';
};

subtest 'atomic write leaves no temp files' => sub {
  my $hash = $m->hash('x', []);
  $m->store({name => 'atomic', hash => $hash, tools => []});
  my @tmp = grep { /\.tmp$/ } map { $_->basename } @{$m->dir->list->to_array};
  is scalar(@tmp), 0, 'no leftover temp files';
};

done_testing;

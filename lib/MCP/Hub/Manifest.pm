package MCP::Hub::Manifest;
our $VERSION = '0.001';
use Mojo::Base -base, -signatures;

use Digest::SHA qw(sha256_hex);
use Mojo::File  qw(path);
use Mojo::JSON  qw(decode_json encode_json);

# ABSTRACT: Read, write and version the cached upstream manifest files

has 'cache_dir';

sub dir ($self) { return path($self->cache_dir, 'manifests') }

sub hash ($self, $command, $args, $cwd = undef) {
  return substr sha256_hex(encode_json([$command, $args // [], $cwd // ''])), 0, 16;
}

sub file ($self, $name, $hash) {
  return $self->dir->child("$name-$hash.json");
}

sub load ($self, $name, $hash) {
  my $file = $self->file($name, $hash);
  return undef unless -f $file;
  my $data = eval { decode_json($file->slurp) };
  return undef unless ref $data eq 'HASH';
  return $data;
}

sub fresh ($self, $name, $hash) {
  my $manifest = $self->load($name, $hash);
  return $manifest && ($manifest->{hash} // '') eq $hash ? 1 : 0;
}

sub store ($self, $manifest) {
  my $dir = $self->dir;
  $dir->make_path unless -d $dir;

  my $file = $self->file($manifest->{name}, $manifest->{hash});
  my $tmp  = $dir->child(".$manifest->{name}-$manifest->{hash}.$$.tmp");
  $tmp->spew(encode_json($manifest));
  rename $tmp, $file or do {
    my $err = $!;
    unlink $tmp;
    die "cannot write manifest $file: $err\n";
  };
  return $file;
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Manifest;

  my $manifest = MCP::Hub::Manifest->new(cache_dir => '~/.cache/mcp-hub');
  my $hash     = $manifest->hash($command, $args, $cwd);

  $manifest->store({name => 'context7', hash => $hash, tools => [...]});
  my $cached = $manifest->load('context7', $hash);

=head1 DESCRIPTION

L<MCP::Hub::Manifest> owns the manifest cache under
C<< <cache_dir>/manifests/ >>. A manifest is the tool, prompt and resource list
an upstream reported at its last handshake, stored so the hub can answer
C<tools/list> from disk without spawning the child process.

The cache file is named C<< <name>-<hash>.json >>, where the hash is the first
16 hex characters of the SHA-256 of C<[command, args, cwd]> -- deliberately
B<not> C<env>, which may hold secrets. A changed command therefore never reuses
a stale manifest. Writes are atomic: a temporary file in the same directory is
written and then renamed into place.

=head1 ATTRIBUTES

=head2 cache_dir

  my $dir = $manifest->cache_dir;

The hub cache directory. Manifests live in its C<manifests/> subdirectory.

=head1 METHODS

=head2 dir

  my $dir = $manifest->dir;

The C<manifests/> directory as a L<Mojo::File>.

=head2 file

  my $file = $manifest->file($name, $hash);

The cache file for a server name and command hash, as a L<Mojo::File>.

=head2 fresh

  my $bool = $manifest->fresh($name, $hash);

True when a manifest for C<$name> is cached and its stored hash matches C<$hash>,
so the cached tool list may be used without re-fetching.

=head2 hash

  my $hash = $manifest->hash($command, $args, $cwd);

The 16-character command hash. C<$args> defaults to an empty list and C<$cwd> to
the empty string.

=head2 load

  my $manifest = $manifest->load($name, $hash);

The cached manifest hash reference, or C<undef> if the file is missing or
corrupt.

=head2 store

  my $file = $manifest->store($manifest);

Atomically write a manifest (which must carry C<name> and C<hash>) to the cache,
creating the directory if needed. Returns the file it wrote.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Hub::Upstream::Stdio>.

=cut

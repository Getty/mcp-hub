package MCP::Hub::Upstream;
our $VERSION = '0.001';
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use Mojo::Log;
use Mojo::Promise;

# ABSTRACT: Base class for an upstream MCP server mounted in the hub

has 'name';
has 'config';
has 'hub';
has log       => sub { Mojo::Log->new };
has 'server';
has state     => 'stopped';
has 'last_used';
has stats     => sub { {calls => 0, errors => 0, started_at => undef, pid => undef} };

sub build ($class, $entry, %opts) {
  my $impl = $entry->{type} eq 'perl' ? 'MCP::Hub::Upstream::Perl' : 'MCP::Hub::Upstream::Stdio';
  return $impl->new(name => $entry->{name}, config => $entry, %opts);
}

sub type ($self) { return $self->config->{type} }

sub manifest_fetched_at ($self) { return $self->{manifest_fetched_at} }

# Default lifecycle -- subclasses override what they need.
sub start_p   ($self) { return Mojo::Promise->resolve($self) }
sub stop      ($self) { return $self }
sub refresh_p ($self) { return Mojo::Promise->resolve($self) }
sub touch     ($self) { $self->last_used(time); return $self }

sub rss_kb ($self) {
  my $pid = $self->stats->{pid} or return undef;
  return _rss($pid);
}

sub status_row ($self) {
  return {
    name                => $self->name,
    type                => $self->type,
    state               => $self->state,
    pid                 => $self->stats->{pid},
    rss_kb              => $self->rss_kb,
    manifest_fetched_at => $self->{manifest_fetched_at},
    last_used           => $self->last_used,
    calls               => $self->stats->{calls},
    errors              => $self->stats->{errors},
  };
}

sub _rss ($pid) {
  open my $fh, '<', "/proc/$pid/status" or return undef;
  while (my $line = <$fh>) { return $1 + 0 if $line =~ /^VmRSS:\s+(\d+)/ }
  return undef;
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Upstream;

  my $upstream = MCP::Hub::Upstream->build($config_entry, hub => $hub);
  $upstream->start_p->then(sub { ... });

=head1 DESCRIPTION

L<MCP::Hub::Upstream> is the common interface for the two kinds of upstream the
hub mounts: a stdio child process (L<MCP::Hub::Upstream::Stdio>) and an
in-process Perl server (L<MCP::Hub::Upstream::Perl>). Each presents its tools,
prompts and resources through an L<MCP::Server> stored in L</server>, which the
hub mounts at C</< name >>.

=head1 ATTRIBUTES

=head2 config

The normalized configuration entry from L<MCP::Hub::Config>.

=head2 hub

The L<MCP::Hub> instance, when mounted in one.

=head2 last_used

Epoch seconds of the last request, updated by L</touch>.

=head2 log

A L<Mojo::Log>.

=head2 name

The server name, and the path it is mounted at.

=head2 server

The L<MCP::Server> agents talk to.

=head2 state

One of C<stopped>, C<starting>, C<ready> or C<failed>.

=head2 stats

Hash reference with C<calls>, C<errors>, C<started_at> and C<pid>.

=head1 METHODS

=head2 build

  my $upstream = MCP::Hub::Upstream->build($entry, hub => $hub);

Construct the right subclass for a configuration entry.

=head2 refresh_p

Re-fetch the manifest and rebuild L</server>. A promise. A no-op for Perl
upstreams.

=head2 rss_kb

Resident set size of the child in kilobytes from C</proc>, or C<undef>.

=head2 start_p

Start the upstream if needed and resolve when it is C<ready>. Idempotent.

=head2 status_row

The per-upstream row of C<GET /_hub/status>.

=head2 stop

Terminate the upstream. A no-op for Perl upstreams.

=head2 touch

Reset L</last_used> and the idle timer.

=head2 type

C<stdio> or C<perl>.

=head1 SEE ALSO

L<MCP::Hub::Upstream::Stdio>, L<MCP::Hub::Upstream::Perl>, L<MCP::Hub>.

=cut

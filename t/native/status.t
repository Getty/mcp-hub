use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::JSON qw(decode_json);
use MCP::Server::Context;
use MCP::Hub::Native::Status;

# --- test doubles ----------------------------------------------------------

package FakeConfig {
  use Mojo::Base -base;
  has 'mode';
}

package FakeHub {
  use Mojo::Base -base, -signatures;
  use Mojo::Promise;
  has mode   => 'open';
  has report => sub {
    {mode => 'open', upstreams => [{name => 'run', type => 'perl', state => 'ready'}], clients => []};
  };
  has counts => sub { {run => 3, context7 => 5} };
  sub status_report ($self) { $self->report }
  sub hub_config    ($self) { FakeConfig->new(mode => $self->mode) }
  sub refresh_p ($self, $name = undef) { Mojo::Promise->resolve($self->counts) }
}

package FakeController {
  use Mojo::Base -base, -signatures;
  has _stash => sub { {} };
  sub stash ($self, @a) {
    return $self->_stash->{$a[0]} if @a == 1;
    my %h = @a;
    $self->_stash->{$_} = $h{$_} for keys %h;
    return $self;
  }
}

package main;

sub tool_named ($server, $name) { return (grep { $_->name eq $name } @{$server->tools})[0] }

sub _await ($result) {
  return $result unless Scalar::Util::blessed($result) && $result->isa('Mojo::Promise');
  my $out;
  $result->then(sub { $out = shift })->wait;
  return $out;
}
use Scalar::Util ();

subtest 'hub_status returns the report' => sub {
  my $hub    = FakeHub->new;
  my $server = MCP::Hub::Native::Status->new(hub => $hub);
  my $tool   = tool_named($server, 'hub_status');
  my $result = _await($tool->call({}, MCP::Server::Context->new));
  my $data   = decode_json($result->{content}[0]{text});
  is $data->{mode}, 'open', 'mode reported';
  is $data->{upstreams}[0]{name}, 'run', 'upstream row present';
};

subtest 'hub_status without a hub errors' => sub {
  my $server = MCP::Hub::Native::Status->new;
  my $tool   = tool_named($server, 'hub_status');
  my $result = _await($tool->call({}, MCP::Server::Context->new));
  ok ${$result->{isError}}, 'error result when no hub';
};

subtest 'hub_refresh in open mode returns counts' => sub {
  my $hub    = FakeHub->new(mode => 'open');
  my $server = MCP::Hub::Native::Status->new(hub => $hub);
  my $tool   = tool_named($server, 'hub_refresh');
  my $result = _await($tool->call({}, MCP::Server::Context->new));
  my $data   = decode_json($result->{content}[0]{text});
  is $data->{context7}, 5, 'counts returned';
};

subtest 'hub_refresh in clients mode needs admin' => sub {
  my $hub    = FakeHub->new(mode => 'clients');
  my $server = MCP::Hub::Native::Status->new(hub => $hub);
  my $tool   = tool_named($server, 'hub_refresh');

  my $denied_ctx = MCP::Server::Context->new(controller => FakeController->new->stash('mcp.profile' => {admin => 0}));
  my $denied = _await($tool->call({}, $denied_ctx));
  ok ${$denied->{isError}}, 'non-admin denied';
  like $denied->{content}[0]{text}, qr/admin/, 'says admin is required';

  my $admin_ctx = MCP::Server::Context->new(controller => FakeController->new->stash('mcp.profile' => {admin => 1}));
  my $allowed = _await($tool->call({}, $admin_ctx));
  my $data = decode_json($allowed->{content}[0]{text});
  is $data->{run}, 3, 'admin allowed, counts returned';
};

done_testing;

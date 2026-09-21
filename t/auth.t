use Mojo::Base -strict, -signatures;
use Test::More;
use MCP::Hub::Config;
use MCP::Hub::Auth;

# --- test doubles ----------------------------------------------------------

package FakeTool {
  use Mojo::Base -base;
  has 'name';
}

package FakeController {
  use Mojo::Base -base, -signatures;
  use Mojo::Message::Request;
  use Mojo::Message::Response;
  has req      => sub { Mojo::Message::Request->new };
  has res      => sub { Mojo::Message::Response->new };
  has _stash   => sub { {} };
  has rendered => sub { {} };
  sub stash ($self, @a) {
    return $self->_stash->{$a[0]} if @a == 1;
    my %h = @a;
    $self->_stash->{$_} = $h{$_} for keys %h;
    return $self;
  }
  sub render ($self, %a) { %{$self->rendered} = %a; return $self }
}

package main;

sub tools (@names) { return [map { FakeTool->new(name => $_) } @names] }
sub names ($tools) { return [map { $_->name } @$tools] }

# --- open mode -------------------------------------------------------------

subtest 'open mode: no token, sees everything, admin' => sub {
  my $config = MCP::Hub::Config->from_data({mcpServers => {a => {command => 'x'}}});
  my $auth   = MCP::Hub::Auth->new(config => $config);
  my $c      = FakeController->new;

  ok $auth->authenticate($c), 'authenticate succeeds without a token';
  my $profile = $c->stash('mcp.profile');
  ok $auth->allows_server($profile, 'a'),        'sees configured server';
  ok $auth->allows_server($profile, 'anything'), 'wildcard sees any server';
  ok $profile->{admin},                          'open profile is admin';
};

# --- clients mode ----------------------------------------------------------

my $clients_config = MCP::Hub::Config->from_data({
  mcpServers => {context7 => {command => 'x'}, serper => {command => 'y'}, secret => {command => 'z'}},
  hub => {
    profiles => {
      full     => {servers => ['*'], admin => \1},
      research => {servers => ['context7', 'serper'], tools => {serper => {deny => ['scrape']}}},
      narrow   => {servers => ['serper'], tools => {serper => {allow => ['search'], deny => ['search']}}},
    },
    clients => {
      main   => {token => 'tok-main',   profile => 'full'},
      worker => {token => 'tok-worker', profile => 'research'},
    },
  },
});

subtest 'clients mode: token resolves to a profile' => sub {
  my $auth = MCP::Hub::Auth->new(config => $clients_config);

  my $c = FakeController->new;
  $c->req->headers->authorization('Bearer tok-worker');
  ok $auth->authenticate($c), 'valid token authenticates';
  is $c->stash('mcp.client'), 'worker', 'client name recorded';

  my $profile = $c->stash('mcp.profile');
  ok $auth->allows_server($profile, 'context7'), 'research sees context7';
  ok !$auth->allows_server($profile, 'secret'),  'research does not see secret';
};

subtest 'clients mode: missing or wrong token is 401' => sub {
  my $auth = MCP::Hub::Auth->new(config => $clients_config);

  my $c = FakeController->new;
  ok !$auth->authenticate($c), 'no token -> not authenticated';
  is $c->rendered->{status}, 401, '401 rendered';
  is $c->res->headers->header('WWW-Authenticate'), 'Bearer', 'challenge header set';

  my $c2 = FakeController->new;
  $c2->req->headers->authorization('Bearer nope');
  ok !$auth->authenticate($c2), 'wrong token -> not authenticated';
  is $c2->rendered->{status}, 401, 'wrong token 401';
};

subtest 'a resolved token records last_seen' => sub {
  my $auth = MCP::Hub::Auth->new(config => $clients_config);
  is_deeply $auth->last_seen, {}, 'nothing seen yet';

  my $before = time;
  my $c      = FakeController->new;
  $c->req->headers->authorization('Bearer tok-worker');
  $auth->authenticate($c);
  ok $auth->last_seen->{worker} >= $before, 'the matching client is stamped with epoch seconds';
  is_deeply [keys %{$auth->last_seen}], ['worker'], 'only the matching client';

  my $bad = FakeController->new;
  $bad->req->headers->authorization('Bearer nope');
  $auth->authenticate($bad);
  is_deeply [keys %{$auth->last_seen}], ['worker'], 'a wrong token stamps nothing';
};

subtest 'public_profile catches tokenless requests' => sub {
  my $config = MCP::Hub::Config->from_data({
    mcpServers => {context7 => {command => 'x'}, secret => {command => 'z'}},
    hub => {
      profiles => {pub => {servers => ['context7']}, full => {servers => ['*']}},
      clients  => {main => {token => 't', profile => 'full'}},
      public_profile => 'pub',
    },
  });
  my $auth = MCP::Hub::Auth->new(config => $config);
  my $c    = FakeController->new;
  ok $auth->authenticate($c), 'tokenless request gets public profile';
  is $c->stash('mcp.client'), undef, 'no client name for public';
  ok $auth->allows_server($c->stash('mcp.profile'), 'context7'), 'public sees context7';
  ok !$auth->allows_server($c->stash('mcp.profile'), 'secret'),  'public does not see secret';
};

# --- tool filtering --------------------------------------------------------

subtest 'deny subtracts tools' => sub {
  my $auth    = MCP::Hub::Auth->new(config => $clients_config);
  my $profile = $clients_config->profiles->{research};
  my $t       = tools(qw(search scrape news));
  $auth->filter_tools($profile, 'serper', $t);
  is_deeply names($t), [qw(search news)], 'scrape denied';
};

subtest 'allow restricts, then deny subtracts' => sub {
  my $auth    = MCP::Hub::Auth->new(config => $clients_config);
  my $profile = $clients_config->profiles->{narrow};
  my $t       = tools(qw(search scrape));
  $auth->filter_tools($profile, 'serper', $t);
  is_deeply names($t), [], 'allow then deny of the same tool leaves nothing';
};

subtest 'no rule means no filtering' => sub {
  my $auth    = MCP::Hub::Auth->new(config => $clients_config);
  my $profile = $clients_config->profiles->{full};
  my $t       = tools(qw(a b c));
  $auth->filter_tools($profile, 'serper', $t);
  is_deeply names($t), [qw(a b c)], 'full profile keeps every tool';
};

subtest 'aggregate filtering by prefix' => sub {
  my $auth    = MCP::Hub::Auth->new(config => $clients_config);
  my $profile = $clients_config->profiles->{research};
  my $t = tools(qw(context7__resolve serper__search serper__scrape secret__leak));
  $auth->filter_aggregate($profile, $t);
  is_deeply names($t), [qw(context7__resolve serper__search)],
    'drops denied tool and server outside the profile';
};

done_testing;

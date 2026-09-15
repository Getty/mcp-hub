package MCP::Hub::Help;
our $VERSION = '0.001';
use Mojo::Base -base, -signatures;

use Mojo::JSON qw(to_json);
use Mojo::Util qw(xml_escape);

# ABSTRACT: The HTML setup page the hub serves at GET /

sub page ($class, $hub, $c) {
  my $config = $hub->hub_config;

  my $base = $c->url_for('/')->to_abs->to_string;
  $base =~ s{/+$}{};

  my $token = $c->param('token');
  if (!defined $token && ($c->req->headers->authorization // '') =~ /^Bearer\s+(\S+)/i) { $token = $1 }

  # Resolve the viewer to a profile.
  my ($profile, $client_name);
  if ($config->mode eq 'open') {
    $profile = $hub->auth->open_profile;
  }
  elsif (defined $token && length $token && (my $client = $hub->auth->resolve_client($token))) {
    $profile     = $config->profiles->{$client->{profile}};
    $client_name = $client->{name};
  }
  elsif (defined(my $public = $config->public_profile)) {
    $profile = $config->profiles->{$public};
  }

  my @servers;
  if ($profile) {
    for my $up (@{$hub->upstreams}) {
      next unless $hub->auth->allows_server($profile, $up->name);
      push @servers, {
        name         => $up->name,
        type         => $up->type,
        state        => $up->state,
        instructions => $up->server->instructions,
        tools        => [map { $_->name } @{$up->server->tools}],
        url          => "$base/@{[$up->name]}",
      };
    }
  }

  return _render({
    mode        => $config->mode,
    base        => $base,
    token       => $token,
    profile     => $profile,
    client_name => $client_name,
    servers     => \@servers,
    invalid     => ($config->mode eq 'clients' && defined $token && length $token && !$profile),
  });
}

# --- rendering -------------------------------------------------------------

sub _render ($v) {
  my $servers = $v->{servers};
  my $auth    = $v->{mode} eq 'clients' && defined $v->{token} && length $v->{token};

  my $body = '';
  $body .= _hero($v);

  if ($v->{mode} eq 'clients' && !$v->{profile}) {
    $body .= _login_form($v->{invalid});
    $body .= _footer();
    return _shell($body);
  }

  if (!@$servers) {
    $body .= qq{<p class="empty">No servers are available to you yet.</p>};
    $body .= _footer();
    return _shell($body);
  }

  # Ready-to-paste .mcp.json
  my %mcp;
  for my $s (@$servers) {
    my $entry = {type => 'http', url => $s->{url}};
    $entry->{headers} = {Authorization => "Bearer $v->{token}"} if $auth;
    $mcp{$s->{name}} = $entry;
  }
  my $json = to_json({mcpServers => \%mcp});
  $json = _pretty($json);

  $body .= _config_section($json, $v, $auth);
  $body .= qq{<h2>Servers you can use</h2>\n};
  $body .= _server_card($_, $v, $auth) for @$servers;
  $body .= _footer();

  return _shell($body);
}

sub _hero ($v) {
  my $who
    = $v->{mode} eq 'open'    ? 'Open mode &mdash; every server is available to everyone.'
    : $v->{client_name}       ? 'Signed in as <strong>' . xml_escape($v->{client_name}) . '</strong>.'
    : $v->{profile}           ? 'Showing the public profile.'
    :                           'Sign in with your token to see your servers.';
  return <<"HTML";
<header>
  <h1>MCP Hub</h1>
  <p class="tagline">A lot of MCP for very little RAM. One endpoint per server, shared across all your agents.</p>
  <p class="who">$who</p>
</header>
HTML
}

sub _login_form ($invalid) {
  my $error = $invalid ? qq{<p class="error">That token was not recognised.</p>} : '';
  return <<"HTML";
<section class="card login">
  <h2>Sign in</h2>
  <p>Paste the bearer token you were given to see the servers you may use and your ready-to-paste configuration.</p>
  $error
  <form method="post" action="/">
    <input type="password" name="token" placeholder="Bearer token" autocomplete="off" autofocus>
    <button type="submit">Show my setup</button>
  </form>
</section>
HTML
}

sub _config_section ($json, $v, $auth) {
  my $note = $auth
    ? qq{<p class="note">This includes your bearer token &mdash; keep it private.</p>}
    : '';
  return <<"HTML";
<section class="card">
  <h2>Add these to your client</h2>
  <p>Drop this into your client's <code>.mcp.json</code> (or Claude Code's MCP config). Each server keeps its own tool names, so your permission rules keep working.</p>
  $note
  <div class="codewrap">
    <button class="copy" data-copy="config">Copy</button>
    <pre id="config">@{[ xml_escape($json) ]}</pre>
  </div>
  <p class="hint">Prefer one endpoint for everything? Point a single server at <code>@{[ xml_escape($v->{base}) ]}/all</code> &mdash; its tools are prefixed with <code>&lt;server&gt;__</code>.</p>
</section>
HTML
}

sub _server_card ($s, $v, $auth) {
  my $name = xml_escape($s->{name});
  my $desc = defined $s->{instructions} && length $s->{instructions}
    ? '<p class="desc">' . xml_escape($s->{instructions}) . '</p>'
    : '';
  my $tools = @{$s->{tools}}
    ? '<p class="tools"><span>Tools:</span> ' . join(', ', map { '<code>' . xml_escape($_) . '</code>' } @{$s->{tools}}) . '</p>'
    : '<p class="tools muted">No tools cached yet &mdash; they appear after the first call.</p>';

  my $header = qq{--header "Authorization: Bearer @{[ $v->{token} // 'YOUR_TOKEN' ]}" };
  my $add    = $auth
    ? qq{claude mcp add --transport http $s->{name} $s->{url} $header}
    : qq{claude mcp add --transport http $s->{name} $s->{url}};

  return <<"HTML";
<section class="card server">
  <h3>$name <span class="badge">@{[ xml_escape($s->{type}) ]}</span></h3>
  $desc
  $tools
  <div class="codewrap">
    <button class="copy" data-copy="add-$name">Copy</button>
    <pre id="add-$name">@{[ xml_escape($add) ]}</pre>
  </div>
</section>
HTML
}

sub _footer {
  return <<'HTML';
<footer>
  <p>Served by <a href="https://metacpan.org/pod/MCP::Hub">MCP::Hub</a>. Run <code>mcp-hub config</code> for the same configuration on the command line.</p>
</footer>
HTML
}

sub _shell ($body) {
  return _head() . $body . _tail();
}

sub _head {
  return <<'HTML';
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MCP Hub</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         background: #f6f7f9; color: #1c2126; }
  .wrap { max-width: 760px; margin: 0 auto; padding: 32px 20px 64px; }
  header { margin-bottom: 28px; }
  h1 { margin: 0; font-size: 30px; letter-spacing: -0.02em; }
  h2 { margin: 0 0 10px; font-size: 18px; }
  h3 { margin: 0 0 8px; font-size: 16px; display: flex; align-items: center; gap: 8px; }
  .tagline { margin: 6px 0 0; color: #5a6470; }
  .who { margin: 14px 0 0; padding: 8px 12px; background: #eaeef3; border-radius: 8px; display: inline-block; }
  .card { background: #fff; border: 1px solid #e3e7ec; border-radius: 12px; padding: 20px; margin: 0 0 18px;
          box-shadow: 0 1px 2px rgba(0,0,0,0.03); }
  .server h3 { margin-bottom: 6px; }
  .badge { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em;
           color: #4b5563; background: #eef1f5; padding: 2px 7px; border-radius: 999px; }
  .desc { margin: 6px 0 10px; color: #3d444d; }
  .tools { margin: 6px 0 12px; color: #3d444d; }
  .tools span { color: #6b7280; }
  .tools.muted { color: #9aa3ad; }
  code { font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
         background: #eef1f5; padding: 1px 5px; border-radius: 5px; }
  .codewrap { position: relative; }
  pre { background: #0f1720; color: #d7e0ea; padding: 14px 16px; border-radius: 10px; overflow-x: auto;
        font: 12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; margin: 0; }
  .copy { position: absolute; top: 8px; right: 8px; font-size: 12px; border: 1px solid #33414f;
          background: #1b2733; color: #cfd8e3; border-radius: 6px; padding: 3px 9px; cursor: pointer; }
  .copy:hover { background: #26333f; }
  .copy.done { color: #7ee2a8; border-color: #2f5a43; }
  .hint, .note { color: #6b7280; font-size: 13px; margin: 10px 0 0; }
  .note { color: #a15c00; }
  .empty { color: #6b7280; }
  form { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 10px; }
  input { flex: 1 1 240px; padding: 9px 12px; border: 1px solid #cdd4dc; border-radius: 8px; font-size: 14px; }
  button[type=submit] { padding: 9px 16px; border: 0; border-radius: 8px; background: #2563eb; color: #fff;
                        font-size: 14px; font-weight: 600; cursor: pointer; }
  button[type=submit]:hover { background: #1d4ed8; }
  .error { color: #c62828; margin: 8px 0 0; }
  footer { margin-top: 8px; color: #8a929c; font-size: 13px; }
  footer a { color: #6b7280; }
  a { color: #2563eb; }
  @media (prefers-color-scheme: dark) {
    body { background: #0d1117; color: #d7dee6; }
    .who { background: #1a2029; }
    .card { background: #161b22; border-color: #262d36; box-shadow: none; }
    .badge { color: #aab4bf; background: #222933; }
    .desc, .tools { color: #b6bfc9; }
    code { background: #222933; color: #d7dee6; }
    input { background: #0d1117; color: #d7dee6; border-color: #2a323c; }
    .tagline, .hint, .empty { color: #8a929c; }
  }
</style>
</head>
<body>
<div class="wrap">
HTML
}

sub _tail {
  return <<'HTML';
</div>
<script>
document.querySelectorAll('.copy').forEach(function (b) {
  b.addEventListener('click', function () {
    var el = document.getElementById(b.dataset.copy);
    if (!el) return;
    navigator.clipboard.writeText(el.textContent).then(function () {
      b.textContent = 'Copied'; b.classList.add('done');
      setTimeout(function () { b.textContent = 'Copy'; b.classList.remove('done'); }, 1500);
    });
  });
});
</script>
</body>
</html>
HTML
}

sub _pretty ($json) {
  # to_json is compact; re-encode with JSON::PP pretty for readability.
  require JSON::PP;
  return JSON::PP->new->pretty->canonical->encode(Mojo::JSON::decode_json($json));
}

1;

=encoding utf8

=head1 SYNOPSIS

  # inside MCP::Hub
  $c->render(text => MCP::Hub::Help->page($self, $c), format => 'html');

=head1 DESCRIPTION

L<MCP::Hub::Help> renders the HTML page the hub serves at C<GET />: a
self-contained setup guide that shows how to add the hub's servers to an MCP
client, with a ready-to-paste C<mcpServers> block and a C<claude mcp add>
command per server.

In open mode it lists every server. In clients mode it shows only a sign-in
form until a valid bearer token is supplied (via the form or an
C<Authorization> header), then the servers and configuration bound to that
client -- so it never leaks which servers exist to an unauthenticated viewer.

The page has no external dependencies, so it works offline behind the daemon.

=head1 METHODS

=head2 page

  my $html = MCP::Hub::Help->page($hub, $c);

Return the HTML for the current request. C<$hub> is the L<MCP::Hub>, C<$c> the
L<Mojolicious::Controller>.

=head1 SEE ALSO

L<MCP::Hub>.

=cut

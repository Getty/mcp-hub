package MCP::Hub::Native::ClaudeHistory;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Server', -signatures;

use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json);

# ABSTRACT: Native MCP server for browsing the local Claude Code history

has root => sub { $ENV{CLAUDE_CONFIG_DIR} || ($ENV{HOME} ? "$ENV{HOME}/.claude" : '.claude') };
has meta_cache => sub { {} };

sub new ($class, %args) {
  my $self = $class->SUPER::new(name => 'claude-history', version => $VERSION, %args);
  $self->instructions('Browse the local Claude Code conversation history.');
  $self->_register;
  return $self;
}

sub _register ($self) {
  $self->tool(
    name         => 'list_projects',
    description  => 'List the projects that have Claude Code history, newest activity first',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) { _json($tool, $self->list_projects) },
  );

  $self->tool(
    name         => 'list_sessions',
    description  => 'List conversation sessions, newest first',
    input_schema => {
      type       => 'object',
      properties => {
        project => {type => 'string', description => 'Restrict to this project path'},
        since   => {type => 'string', description => 'Only sessions active on or after this date (YYYY-MM-DD or ISO)'},
        until   => {type => 'string', description => 'Only sessions active on or before this date'},
        limit   => {type => 'integer', description => 'Maximum sessions to return (default 50)'},
      },
    },
    code => sub ($tool, $args) { _json($tool, $self->list_sessions($args)) },
  );

  $self->tool(
    name         => 'search_conversations',
    description  => 'Case-insensitive substring search across conversation text',
    input_schema => {
      type       => 'object',
      properties => {
        query   => {type => 'string', description => 'Substring to search for'},
        project => {type => 'string'},
        since   => {type => 'string'},
        until   => {type => 'string'},
        roles   => {type => 'array', items => {type => 'string'}, description => 'Roles to search (default ["user"])'},
        limit   => {type => 'integer', description => 'Maximum matches (default 30)'},
      },
      required => ['query'],
    },
    code => sub ($tool, $args) { _json($tool, $self->search_conversations($args)) },
  );

  $self->tool(
    name         => 'get_conversation',
    description  => 'Read the messages of one conversation session',
    input_schema => {
      type       => 'object',
      properties => {
        session_id => {type => 'string'},
        offset     => {type => 'integer', description => 'Skip this many messages (default 0)'},
        limit      => {type => 'integer', description => 'Maximum messages (default 50)'},
        roles      => {type => 'array', items => {type => 'string'}, description => 'Roles to include (default user, assistant)'},
      },
      required => ['session_id'],
    },
    code => sub ($tool, $args) { _json($tool, $self->get_conversation($args)) },
  );

  return $self;
}

# --- tool implementations --------------------------------------------------

sub list_projects ($self) {
  my @projects;
  for my $dir ($self->_project_dirs) {
    my @sessions = $self->_sessions_in($dir);
    next unless @sessions;
    my $last = (sort { $b->{last_activity} cmp $a->{last_activity} } @sessions)[0];
    push @projects, {
      project       => $last->{project},
      dir           => $dir->basename,
      sessions      => scalar(@sessions),
      last_activity => $last->{last_activity},
    };
  }
  return [sort { ($b->{last_activity} // '') cmp($a->{last_activity} // '') } @projects];
}

sub list_sessions ($self, $args = {}) {
  my $limit = $args->{limit} // 50;
  my @sessions;
  for my $dir ($self->_project_dirs) {
    push @sessions, $self->_sessions_in($dir);
  }
  @sessions = grep { !defined $args->{project} || $_->{project} eq $args->{project} } @sessions;
  @sessions = grep { _in_range($_->{last_activity}, $args->{since}, $args->{until}) } @sessions;
  @sessions = sort { $b->{last_activity} cmp $a->{last_activity} } @sessions;
  @sessions = @sessions[0 .. $limit - 1] if @sessions > $limit;
  return [@sessions];
}

sub search_conversations ($self, $args) {
  my $query = $args->{query} // '';
  my $limit = $args->{limit} // 30;
  my %roles = map { $_ => 1 } @{$args->{roles} // ['user']};
  my $needle = lc $query;

  my @hits;
  my $sessions = $self->list_sessions({project => $args->{project}, since => $args->{since}, until => $args->{until}, limit => 1e9});
  for my $session (@$sessions) {
    last if @hits >= $limit;
    for my $entry (@{$self->_entries($session->{_file})}) {
      next unless $roles{$entry->{role}};
      my $text = $entry->{text} // '';
      next unless (my $pos = index(lc $text, $needle)) >= 0;
      push @hits, {
        session_id => $session->{session_id},
        project    => $session->{project},
        timestamp  => $entry->{timestamp},
        role       => $entry->{role},
        snippet    => _snippet($text, $pos, length $query),
      };
      last if @hits >= $limit;
    }
  }
  return [@hits];
}

sub get_conversation ($self, $args) {
  my $offset = $args->{offset} // 0;
  my $limit  = $args->{limit}  // 50;
  my %roles  = map { $_ => 1 } @{$args->{roles} // ['user', 'assistant']};

  my $file = $self->_file_for_session($args->{session_id});
  return {entries => [], total => 0, has_more => \0} unless $file;

  my @entries = grep { $roles{$_->{role}} } @{$self->_entries($file)};
  my $total   = scalar @entries;
  my @page    = @entries[$offset .. ($offset + $limit - 1 < $#entries ? $offset + $limit - 1 : $#entries)];
  @page = () if $offset > $#entries;

  return {
    entries  => [map { {uuid => $_->{uuid}, timestamp => $_->{timestamp}, role => $_->{role}, text => $_->{text}} } @page],
    total    => $total,
    has_more => ($offset + $limit < $total ? \1 : \0),
  };
}

# --- reading and caching ---------------------------------------------------

sub _project_dirs ($self) {
  my $projects = path($self->root, 'projects');
  return () unless -d $projects;
  return grep { -d $_ } @{$projects->list({dir => 1})->to_array};
}

sub _sessions_in ($self, $dir) {
  my @sessions;
  for my $file (@{$dir->list->to_array}) {
    next unless $file->basename =~ /\.jsonl$/;
    push @sessions, $self->_meta($file);
  }
  return @sessions;
}

sub _meta ($self, $file) {
  my @stat = stat "$file";
  my $key  = "$stat[9]:$stat[7]";    # mtime:size
  my $cached = $self->meta_cache->{"$file"};
  return {%{$cached->{meta}}, _file => "$file"} if $cached && $cached->{key} eq $key;

  my $meta = $self->_scan($file);
  $self->meta_cache->{"$file"} = {key => $key, meta => $meta};
  return {%$meta, _file => "$file"};
}

sub _scan ($self, $file) {
  my ($session_id, $project, $started, $last, $count, $first_prompt, $title, $branch);
  for my $line (split /\n/, path($file)->slurp) {
    next unless length $line;
    my $rec = eval { decode_json($line) } or next;

    $session_id //= $rec->{sessionId};
    $project    //= $rec->{cwd};
    $branch     //= $rec->{gitBranch};
    $started    //= $rec->{timestamp};
    $last = $rec->{timestamp} if defined $rec->{timestamp};

    my $type = $rec->{type} // '';
    $title = $rec->{aiTitle} if $type eq 'ai-title';

    if ($type eq 'user' || $type eq 'assistant') {
      $count++;
      $first_prompt //= _text($rec->{message}) if $type eq 'user';
    }
  }

  $project //= $self->_dir_to_path($file->dirname->basename);
  return {
    session_id    => $session_id // $file->basename =~ s/\.jsonl$//r,
    project       => $project,
    started_at    => $started,
    last_activity => $last // $started,
    messages      => $count // 0,
    first_prompt  => $first_prompt,
    title         => $title,
    git_branch    => $branch,
  };
}

sub _entries ($self, $file) {
  my @entries;
  for my $line (split /\n/, path($file)->slurp) {
    next unless length $line;
    my $rec = eval { decode_json($line) } or next;
    my $type = $rec->{type} // '';
    next unless $type eq 'user' || $type eq 'assistant';
    push @entries, {
      uuid      => $rec->{uuid},
      timestamp => $rec->{timestamp},
      role      => $type,
      text      => _text($rec->{message}),
    };
  }
  return \@entries;
}

sub _file_for_session ($self, $session_id) {
  for my $dir ($self->_project_dirs) {
    for my $file (@{$dir->list->to_array}) {
      next unless $file->basename =~ /\.jsonl$/;
      my $meta = $self->_meta($file);
      return $file if ($meta->{session_id} // '') eq $session_id;
    }
  }
  return undef;
}

# --- helpers ---------------------------------------------------------------

sub _text ($message) {
  return '' unless ref $message eq 'HASH';
  my $content = $message->{content};
  return $content unless ref $content eq 'ARRAY';

  my @parts;
  for my $block (@$content) {
    next unless ref $block eq 'HASH';
    my $type = $block->{type} // '';
    if    ($type eq 'text')        { push @parts, $block->{text} // '' }
    elsif ($type eq 'tool_use')    { push @parts, "[tool_use $block->{name}]" }
    elsif ($type eq 'tool_result') { push @parts, '[tool_result]' }
  }
  return join "\n", @parts;
}

sub _snippet ($text, $pos, $len) {
  my $start = $pos - 120 < 0 ? 0 : $pos - 120;
  my $slice = substr $text, $start, $len + 240;
  $slice =~ s/\s+/ /g;
  return $slice;
}

sub _in_range ($value, $since, $until) {
  return 1 unless defined $value;
  if (defined $since) { return 0 if $value lt _norm($since, 0) }
  if (defined $until) { return 0 if $value gt _norm($until, 1) }
  return 1;
}

sub _norm ($date, $end) {
  return $date unless $date =~ /^\d{4}-\d{2}-\d{2}$/;
  return $end ? "${date}T23:59:59Z" : "${date}T00:00:00Z";
}

sub _dir_to_path ($self, $dir) {
  (my $path = $dir) =~ s{-}{/}g;
  return $path;
}

sub _json ($tool, $data) {
  return {
    content           => [{type => 'text', text => encode_json($data)}],
    structuredContent => (ref $data eq 'HASH' ? $data : {results => $data}),
  };
}

1;

=encoding utf8

=head1 SYNOPSIS

  use MCP::Hub::Native::ClaudeHistory;

  my $server = MCP::Hub::Native::ClaudeHistory->new;
  $server->to_stdio;    # or mount it in the hub

=head1 DESCRIPTION

L<MCP::Hub::Native::ClaudeHistory> is a native Perl replacement for the Claude
Code history MCP server, which today costs a ~120 MB node process per session.
It reads the JSONL session files under C<$CLAUDE_CONFIG_DIR/projects> (or
C<~/.claude/projects>) and offers four tools.

Per-session metadata is cached in memory keyed by C<(mtime, size)>, so repeated
listings do not re-read unchanged files.

=head2 Tools

=over 2

=item C<list_projects>

C<[{project, dir, sessions, last_activity}]>, newest activity first.

=item C<list_sessions>

Arguments C<project?>, C<since?>, C<until?>, C<limit> (50). Returns
C<[{session_id, project, started_at, last_activity, messages, first_prompt,
title, git_branch}]>, newest first.

=item C<search_conversations>

Arguments C<query> (required), C<project?>, C<since?>, C<until?>, C<roles>
(C<["user"]>), C<limit> (30). Case-insensitive substring match, snippet ±120
characters.

=item C<get_conversation>

Arguments C<session_id> (required), C<offset> (0), C<limit> (50), C<roles>
(C<["user","assistant"]>). Returns C<< {entries, total, has_more} >>, with
C<tool_use> blocks rendered as C<[tool_use <name>]> and C<tool_result> as
C<[tool_result]>.

=back

=head1 ATTRIBUTES

L<MCP::Hub::Native::ClaudeHistory> inherits all attributes from L<MCP::Server>
and adds:

=attr root

The Claude configuration directory. Defaults to C<$CLAUDE_CONFIG_DIR> or
C<~/.claude>.

=head1 METHODS

The four tools are also plain methods (C<list_projects>, C<list_sessions>,
C<search_conversations>, C<get_conversation>) taking an arguments hash reference,
so they can be tested without going through the MCP layer.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Hub::Native::ClaudeSessions>, L<MCP::Server>.

=cut

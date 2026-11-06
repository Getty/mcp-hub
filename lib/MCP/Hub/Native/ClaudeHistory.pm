package MCP::Hub::Native::ClaudeHistory;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Server', -signatures;

use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json);
use Scalar::Util qw(weaken);

# ABSTRACT: Native MCP server for browsing the local Claude Code history

has root => sub { $ENV{CLAUDE_CONFIG_DIR} || ($ENV{HOME} ? "$ENV{HOME}/.claude" : '.claude') };
has meta_cache => sub { {} };

# Escapes that decode to a character a raw search needle can match: printable
# ASCII, U+0130 and U+212A (see _raw_skip); and text, name and content values
# that are not strings, which _text stringifies.
my $ESCAPE        = qr/\\u(?:00[2-7][0-9a-fA-F]|0130|212[aA])/;
my $TEXT_VALUE    = qr/"text"[\x20\t\r\n]*:[\x20\t\r\n]*[^"\x20\t\r\n]/;
my $NAME_VALUE    = qr/"name"[\x20\t\r\n]*:[\x20\t\r\n]*[^"\x20\t\r\n]/;
my $CONTENT_VALUE = qr/"content"[\x20\t\r\n]*:[\x20\t\r\n]*[^"\[\x20\t\r\n]/;

sub new ($class, %args) {
  my $self = $class->SUPER::new(name => 'claude-history', version => $VERSION, %args);
  $self->instructions('Browse the local Claude Code conversation history.');
  $self->_register;
  return $self;
}

# The tools reach this server weakly: it holds them, so a strong reference back
# would be a cycle, and an instance that a configuration reload drops would
# never be freed. Whoever mounts the server keeps it alive; a tool that outlived
# it answers with an error result.
sub _register ($self) {
  my $gone = $self->name . ': gone, the server of this tool was freed';
  weaken $self;

  $self->tool(
    name         => 'list_projects',
    description  => 'List the projects that have Claude Code history, newest activity first',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) {
      return $tool->text_result($gone, 1) unless $self;
      return _json($tool, $self->list_projects);
    },
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
    code => sub ($tool, $args) {
      return $tool->text_result($gone, 1) unless $self;
      return _json($tool, $self->list_sessions($args));
    },
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
    code => sub ($tool, $args) {
      return $tool->text_result($gone, 1) unless $self;
      return _json($tool, $self->search_conversations($args));
    },
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
    code => sub ($tool, $args) {
      return $tool->text_result($gone, 1) unless $self;
      return _json($tool, $self->get_conversation($args));
    },
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
  my $skip   = _raw_skip($needle);

  # Up to $want matches of one file, in file order.
  my $match = sub ($rec, $found, $want) {
    return if @$found >= $want;
    my $role = $rec->{type} // '';
    return unless ($role eq 'user' || $role eq 'assistant') && $roles{$role};
    my $text = _text($rec->{message}) // '';
    return unless (my $pos = index(lc $text, $needle)) >= 0;
    push @$found, {timestamp => $rec->{timestamp}, role => $role, snippet => _snippet($text, $pos, length $query)};
  };

  # A file whose metadata is out of date is read once, for the metadata and the
  # matches together; on a cold cache that is every file.
  my %found;
  for my $file (map { _session_files($_) } $self->_project_dirs) {
    my @found;
    $found{"$file"} = \@found if $self->_refresh($file, $skip, sub ($rec) { $match->($rec, \@found, $limit) });
  }

  my @hits;
  my $sessions = $self->list_sessions({project => $args->{project}, since => $args->{since}, until => $args->{until}, limit => 1e9});
  for my $session (@$sessions) {
    last if @hits >= $limit;
    my $found = $found{$session->{_file}};
    unless ($found) {
      $found = [];
      my $want = $limit - @hits;
      _each_record($session->{_file}, $skip, sub ($rec) { $match->($rec, $found, $want) });
    }
    for my $hit (@$found) {
      push @hits, {session_id => $session->{session_id}, project => $session->{project}, %$hit};
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

sub _session_files ($dir) {
  return grep { $_->basename =~ /\.jsonl$/ } @{$dir->list->to_array};
}

sub _sessions_in ($self, $dir) {
  return map { $self->_meta($_) } _session_files($dir);
}

sub _meta ($self, $file) {
  $self->_refresh($file);
  return {%{$self->meta_cache->{"$file"}{meta}}, _file => "$file"};
}

# Brings the cached metadata of $file up to date. The cache keeps the file's
# device, inode, size and mtime, the offset after the last whole line read, and
# the scan's state at that offset. A file that only grew is read from that
# offset on; a new one, or one that shrank, was replaced (another inode) or
# changed without growing, is read from the start. With $visit, a file that has
# to be read at all is read from the start, and $visit sees every record
# of it -- lines before the offset only if the raw test $skip lets them
# through. Returns whether the file was read.
sub _refresh ($self, $file, $skip = undef, $visit = undef) {
  my $old  = $self->meta_cache->{"$file"};
  my $same = sub (@stat) { $old && @stat && $old->{dev} == $stat[0] && $old->{ino} == $stat[1] };
  my @stat = stat "$file";
  return 0 if $same->(@stat) && $old->{size} == $stat[7] && $old->{mtime} == $stat[9];

  # Whether the file only grew is decided on the handle read, not the path.
  my $fh    = path($file)->open('<:raw');
  my @fstat = stat $fh;
  my $grown = $same->(@fstat) && $fstat[7] > $old->{size};
  my $from  = $grown ? $old->{offset} : 0;
  my %state = $grown ? %{$old->{state}} : ();
  my $tail;
  my ($offset, $size) = _lines($fh, $visit ? 0 : $from, sub ($line, $start, $whole) {
    my $rec;
    if ($start >= $from) {
      $rec = _record($line) or return;
      # An unterminated last line counts for now, but is read again next time.
      if ($whole) { _absorb(\%state, $rec) }
      else        { _absorb($tail = {%state}, $rec) }
    }
    else {
      return if $skip && $skip->($line);
      $rec = _record($line) or return;
    }
    $visit->($rec) if $visit;
  });

  @fstat = stat $fh;
  $self->meta_cache->{"$file"} = {
    dev    => $fstat[0],
    ino    => $fstat[1],
    size   => $size,
    mtime  => $fstat[9],
    offset => $offset,
    state  => \%state,
    meta   => $self->_summary($file, $tail // \%state),
  };
  return 1;
}

sub _absorb ($state, $rec) {
  $state->{session_id} //= $rec->{sessionId};
  $state->{project}    //= $rec->{cwd};
  $state->{branch}     //= $rec->{gitBranch};
  $state->{started}    //= $rec->{timestamp};
  $state->{last} = $rec->{timestamp} if defined $rec->{timestamp};

  my $type = $rec->{type} // '';
  $state->{title} = $rec->{aiTitle} if $type eq 'ai-title';

  if ($type eq 'user' || $type eq 'assistant') {
    $state->{count}++;
    $state->{first_prompt} //= _text($rec->{message}) if $type eq 'user';
  }
}

sub _summary ($self, $file, $state) {
  return {
    session_id    => $state->{session_id} // $file->basename =~ s/\.jsonl$//r,
    project       => $state->{project} // $self->_dir_to_path($file->dirname->basename),
    started_at    => $state->{started},
    last_activity => $state->{last} // $state->{started},
    messages      => $state->{count} // 0,
    first_prompt  => $state->{first_prompt},
    title         => $state->{title},
    git_branch    => $state->{branch},
  };
}

sub _entries ($self, $file) {
  my @entries;
  _each_record($file, undef, sub ($rec) { my $entry = _entry($rec) or return; push @entries, $entry });
  return \@entries;
}

# Every record of $file (see _record). With a raw test, a line is decoded only
# if its raw bytes could hold a match.
sub _each_record ($file, $skip, $cb) {
  _lines(path($file)->open('<:raw'), 0, sub ($line, @) {
    return if $skip && $skip->($line);
    my $rec = _record($line) or return;
    $cb->($rec);
  });
}

# The record a line holds: the object it decodes to, or undef for a line that
# is not JSON, or is JSON but not an object ([1], 42, "x").
sub _record ($line) {
  my $rec = eval { decode_json($line) };
  return ref $rec eq 'HASH' ? $rec : undef;
}

sub _entry ($rec) {
  my $type = $rec->{type} // '';
  return undef unless $type eq 'user' || $type eq 'assistant';
  return {uuid => $rec->{uuid}, timestamp => $rec->{timestamp}, role => $type, text => _text($rec->{message})};
}

# Calls $cb->($line, $start, $whole) for every non-empty line read from $fh
# from byte $from on, one line in memory at a time; $whole is false for a last
# line without its newline. Returns the offset after the last whole line and
# the offset reached.
sub _lines ($fh, $from, $cb) {
  seek $fh, $from, 0 if $from;
  my ($pos, $offset) = ($from, $from);
  while (my $line = <$fh>) {
    my $start = $pos;
    $pos += length $line;
    my $whole = chomp $line;
    $offset = $pos if $whole;
    $cb->($line, $start, $whole) if length $line;
  }
  return $offset, $pos;
}

# Claude Code names a session's file after the session, so a file of that name
# is read first; only if none holds the session are the others read. The
# session_id is compared with the names of the files listed, never made into a
# path, so it cannot reach outside the projects dir.
sub _file_for_session ($self, $session_id) {
  my @files = map { _session_files($_) } $self->_project_dirs;
  my $name  = "$session_id.jsonl";
  for my $file ((grep { $_->basename eq $name } @files), (grep { $_->basename ne $name } @files)) {
    my $meta = $self->_meta($file);
    return $file if ($meta->{session_id} // '') eq $session_id;
  }
  return undef;
}

# --- helpers ---------------------------------------------------------------

# For a search needle (already lowercased) that can be tested against the raw
# JSON line, a test that is true for a line which cannot hold a match, so the
# search need not decode it; undef for any other needle, which has every line
# decoded. The needle must be printable ASCII without anything JSON escapes
# ('"', '\'), so a match in the decoded text is one in the raw bytes, and must
# not be able to match the markers _text adds: no '[' or ']', and not starting
# inside "[tool_use " (e.g. "use bash"). A line still counts as a candidate if
# it can decode to a match without holding the needle raw: an escaped printable
# ASCII character, a slash escaped as \/ when the needle holds '/', KELVIN SIGN
# (lowercase "k") or U+0130 (lowercase "i\x{307}") when it holds that letter,
# or a non-string text, name or content value when the needle could be such a
# value stringified (1e5 is "100000", true "1", an object "HASH(0x...)").
sub _raw_skip ($needle) {
  return undef unless $needle =~ /\A[\x20-\x7e]+\z/ && $needle !~ /["\\\[\]]/;
  return undef if grep { index($needle, substr('[tool_use ', $_)) == 0 } 1 .. 9;

  my $slash  = index($needle, '/') >= 0;
  my $kelvin = index($needle, 'k') >= 0;
  my $dot_i  = index($needle, 'i') >= 0;
  my $scalar = $needle =~ /\A[0-9a-fhinrsxy().+\-]+\z/;
  return sub ($line) {
    return !(index(lc $line, $needle) >= 0
      || (index($line, '\\u') >= 0 && $line =~ $ESCAPE)
      || ($slash  && index($line, '\\/') >= 0)
      || ($kelvin && index($line, "\xE2\x84\xAA") >= 0)
      || ($dot_i  && index($line, "\xC4\xB0") >= 0)
      || ($scalar && ($line =~ $TEXT_VALUE || $line =~ $NAME_VALUE || $line =~ $CONTENT_VALUE)));
  };
}

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

Session files are read a line at a time. Per-session metadata is cached in
memory together with the file's device, inode, size, modification time and the
offset its scan reached: an unchanged file is not read again, a file that grew
is read only from that offset on, and a file that shrank, was replaced or was
rewritten without growing is read again from the start. A search reads a file
whose metadata is out of date only once, for both. C<get_conversation> reads
the file named after the session (C<< <session_id>.jsonl >>, as Claude Code
names it) first, and the others only if that one does not hold the session.

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

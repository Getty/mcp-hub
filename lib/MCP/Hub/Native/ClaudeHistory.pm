package MCP::Hub::Native::ClaudeHistory;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Server', -signatures;

use JSON::MaybeXS ();
use Mojo::File qw(path);
use Mojo::JSON qw(encode_json to_json);
use Scalar::Util qw(weaken);
use Time::Local qw(timegm);

# ABSTRACT: Native MCP server for browsing the local Claude Code history

has root => sub { $ENV{CLAUDE_CONFIG_DIR} || ($ENV{HOME} ? "$ENV{HOME}/.claude" : '.claude') };
has meta_cache => sub { {} };

# The lines of a session file are decoded by JSON::MaybeXS, which picks
# Cpanel::JSON::XS where it is installed: on a history of many megabytes, a
# fraction of a second where pure Perl takes many. A line that holds a key
# twice is read as Mojo::JSON reads it, the last value winning, where
# Cpanel::JSON::XS would refuse the line.
my $JSON = JSON::MaybeXS->new(utf8 => 1);
$JSON->allow_dupkeys if $JSON->can('allow_dupkeys');

# A line's bytes, decoded; dies on a line that is not JSON. Every line read,
# and every subagent run's meta file, is decoded here, and only here.
sub decode_json ($bytes) { $JSON->decode($bytes) }

# Escapes that decode to a character a raw search needle can match: printable
# ASCII, U+0130 and U+212A (see _raw_skip); and text, name and content values
# that are not strings but that _text makes into one: a number or boolean, as
# any of the three, into its string (1e5 is "100000", 1e999 "Inf", true "1").
# Null _text makes into no text; these tests let it through all the same. An
# object, as any of the three, and an array as text or name, _text makes into
# no text too, and these tests do not let them through; nor an array as
# content, whose blocks' text and names they test. A display value, the text
# of a line of the prompt history, _string makes into a string as _text does a
# text value, and its test is that of one.
my $ESCAPE        = qr/\\u(?:00[2-7][0-9a-fA-F]|0130|212[aA])/;
my $TEXT_VALUE    = qr/"text"[\x20\t\r\n]*:[\x20\t\r\n]*[^"\[{\x20\t\r\n]/;
my $NAME_VALUE    = qr/"name"[\x20\t\r\n]*:[\x20\t\r\n]*[^"\[{\x20\t\r\n]/;
my $CONTENT_VALUE = qr/"content"[\x20\t\r\n]*:[\x20\t\r\n]*[^"\[{\x20\t\r\n]/;
my $DISPLAY_VALUE = qr/"display"[\x20\t\r\n]*:[\x20\t\r\n]*[^"\[{\x20\t\r\n]/;

# An ISO 8601 date, alone or with a time (see _iso_ms): the date; the hours,
# minutes, seconds and fraction; the sign, hours and minutes of an offset.
my $ISO_TIME = qr/
  \A([0-9]{4})-([0-9]{2})-([0-9]{2})
  (?:[Tt\x20]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]+))?)?
    (?:[Zz]|([+-])([01][0-9]|2[0-3])(?::?([0-5][0-9]))?)?)?\z
/x;

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
      my $sessions = $self->list_sessions($args) // return $self->_no_time($tool, $args);
      return _json($tool, $sessions);
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
        include_subagents => {
          type        => 'boolean',
          description => 'Also search the subagent runs of each session (default false); their matches carry agent_id',
        },
      },
      required => ['query'],
    },
    code => sub ($tool, $args) {
      return $tool->text_result($gone, 1) unless $self;
      my $hits = $self->search_conversations($args) // return $self->_no_time($tool, $args);
      return _json($tool, $hits);
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
        agent_id   => {type => 'string', description => 'Read this subagent run of the session instead (see list_subagents)'},
      },
      required => ['session_id'],
    },
    code => sub ($tool, $args) {
      return $tool->text_result($gone, 1) unless $self;
      my $conversation = $self->get_conversation($args);
      return _json($tool, $conversation) if $conversation;
      my $missing = $self->name . ': no subagent run ' . $args->{agent_id} . ' in session ' . $args->{session_id};
      return $tool->text_result($missing, 1);
    },
  );

  $self->tool(
    name         => 'list_subagents',
    description  => 'List the subagent runs of one conversation session, in the order they started',
    input_schema => {
      type       => 'object',
      properties => {session_id => {type => 'string'}},
      required   => ['session_id'],
    },
    code => sub ($tool, $args) {
      return $tool->text_result($gone, 1) unless $self;
      return _json($tool, $self->list_subagents($args));
    },
  );

  $self->tool(
    name         => 'list_prompts',
    description  => 'List the prompts typed into Claude Code, newest first, from its prompt history,'
      . ' which also keeps the prompts of sessions whose transcript is gone',
    input_schema => {
      type       => 'object',
      properties => {
        query   => {type => 'string', description => 'Only prompts holding this substring (case-insensitive)'},
        project => {type => 'string', description => 'Restrict to this project path'},
        since   => {type => 'string', description => 'Only prompts on or after this date (YYYY-MM-DD or ISO)'},
        until   => {type => 'string', description => 'Only prompts on or before this date'},
        limit   => {type => 'integer', description => 'Maximum prompts to return (default 50)'},
      },
    },
    code => sub ($tool, $args) {
      return $tool->text_result($gone, 1) unless $self;
      my $prompts = $self->list_prompts($args) // return $self->_no_time($tool, $args);
      return _json($tool, $prompts);
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
    my ($last) = _by_time(-1, $self->_timed(last_activity => undef, @sessions));
    push @projects, {
      project       => $last->{project},
      dir           => $dir->basename,
      sessions      => scalar(@sessions),
      last_activity => $last->{last_activity},
    };
  }
  return [_by_time(-1, $self->_timed(last_activity => undef, @projects))];
}

sub list_sessions ($self, $args = {}) {
  my $sessions = $self->_sessions($args) // return undef;
  delete $_->{_file} for @$sessions;
  return $sessions;
}

# The sessions list_sessions returns, each a copy of the cached metadata that
# also holds, as _file, the path of its session file; search_conversations
# reads that file, list_sessions sends no path of this host. Undef for a since
# or until that is no time. The since and until, and the order, compare a
# session's time as the instant the cache worked out (see _timed).
sub _sessions ($self, $args) {
  my $range = _range($args) // return undef;
  my $limit = $args->{limit} // 50;
  my @sessions;
  for my $dir ($self->_project_dirs) {
    push @sessions, $self->_sessions_in($dir);
  }
  my @timed = grep { _filtered($args, $range, $_->[3]{project}, $_->[0]) }
    $self->_timed(last_activity => undef, @sessions);
  @sessions = _by_time(-1, @timed);
  @sessions = @sessions[0 .. $limit - 1] if @sessions > $limit;
  return [@sessions];
}

sub search_conversations ($self, $args) {
  return undef unless _range($args);
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
  my $scan = sub ($run, @files) {
    for my $file (@files) {
      my @found;
      $found{"$file"} = \@found if $self->_refresh($file, $skip, sub ($rec) { $match->($rec, \@found, $limit) }, $run);
    }
  };
  $scan->(0, map { _session_files($_) } $self->_project_dirs);

  # The matches of one file, each with %of, until the limit is reached.
  my @hits;
  my $take = sub ($file, %of) {
    my $found = $found{$file};
    unless ($found) {
      $found = [];
      my $want = $limit - @hits;
      _each_record($file, $skip, sub ($rec) { $match->($rec, $found, $want) });
    }
    for my $hit (@$found) {
      push @hits, {%of, %$hit};
      last if @hits >= $limit;
    }
  };

  # A session's own matches come first, then those of its subagent runs, run
  # by run in the order they started. The runs are read only if asked for.
  my $sessions = $self->_sessions({project => $args->{project}, since => $args->{since}, until => $args->{until}, limit => 1e9});
  for my $session (@$sessions) {
    last if @hits >= $limit;
    my %of = (session_id => $session->{session_id}, project => $session->{project});
    $take->($session->{_file}, %of);
    next unless $args->{include_subagents} && @hits < $limit;
    my @runs = _run_files($session->{_file});
    $scan->(1, @runs);
    for my $run ($self->_runs(@runs)) {
      last if @hits >= $limit;
      $take->($run->{_file}, %of, agent_id => $run->{agent_id});
    }
  }
  return [@hits];
}

sub get_conversation ($self, $args) {
  my $offset = $args->{offset} // 0;
  my $limit  = $args->{limit}  // 50;
  my %roles  = map { $_ => 1 } @{$args->{roles} // ['user', 'assistant']};
  my $agent_id = $args->{agent_id};

  my ($file, $entries) = $self->_file_for_session($args->{session_id}, !defined $agent_id);
  return {entries => [], total => 0, has_more => \0} unless $file;

  # The agent_id is compared with the names of the run files listed, never
  # made into a path, as a session_id is.
  if (defined $agent_id) {
    ($file) = grep { _agent_id($_) eq $agent_id } _run_files($file);
    return unless $file;
  }

  my @entries = grep { $roles{$_->{role}} } @{$entries // $self->_entries($file)};
  my $total   = scalar @entries;
  my @page    = @entries[$offset .. ($offset + $limit - 1 < $#entries ? $offset + $limit - 1 : $#entries)];
  @page = () if $offset > $#entries;

  return {
    entries  => [map { {uuid => $_->{uuid}, timestamp => $_->{timestamp}, role => $_->{role}, text => $_->{text}} } @page],
    total    => $total,
    has_more => ($offset + $limit < $total ? \1 : \0),
  };
}

# A run's type and description come from its meta file, null where it is
# missing or unreadable; its times and message count from its lines.
sub list_subagents ($self, $args) {
  my ($file) = $self->_file_for_session($args->{session_id}, 0);
  return [] unless $file;

  my @runs = $self->_runs(_run_files($file));
  for my $run (@runs) {
    my $meta = $self->_run_meta(delete $run->{_file});
    $run->{agent_type}  = _string($meta->{agentType});
    $run->{description} = _string($meta->{description});
  }
  return \@runs;
}

# Claude Code's prompt history, history.jsonl in the root: a line per prompt
# typed, kept after the session's own file is deleted. Claude Code appends to
# it, and writes it anew when it prunes it; so it is read whole on every call,
# a line at a time, and nothing of it is cached. Of the matches, only the
# newest $limit are kept, oldest first; a later line of the same time counts as
# the newer one. Of a line, its display goes out as the text, which holds
# pasted text only as Claude Code's placeholders; its pasted contents never
# do. A session has its transcript where a session file is named after it,
# which is found from the names of the files, none of them read.
sub list_prompts ($self, $args = {}) {
  my $range = _range($args) // return undef;
  my $file  = path($self->root, 'history.jsonl');
  return [] unless -f $file;

  my $limit  = $args->{limit} // 50;
  my $needle = defined $args->{query} ? lc $args->{query} : undef;
  my $skip   = defined $needle ? _raw_skip($needle, $DISPLAY_VALUE) : undef;

  my @kept;
  _each_record($file, $skip, sub ($rec) {
    my $text = _string($rec->{display}) // return;
    return if defined $needle && index(lc $text, $needle) < 0;
    my $ms      = _ms($rec->{timestamp});
    my $project = _string($rec->{project});
    return unless _filtered($args, $range, $project, $ms);

    my $key = $ms // -1;
    return if @kept >= $limit && @kept && $key < $kept[0][0];
    my ($lo, $hi) = (0, scalar @kept);
    while ($lo < $hi) {
      my $mid = ($lo + $hi) >> 1;
      if   ($kept[$mid][0] > $key) { $hi = $mid }
      else                         { $lo = $mid + 1 }
    }
    splice @kept, $lo, 0, [$key, $ms, $text, $project, $rec->{sessionId}];
    shift @kept while @kept > $limit;
  });
  return [] unless @kept;

  # The names of the session files, as _session_files finds them.
  my %transcript;
  for my $dir ($self->_project_dirs) {
    opendir my $dh, "$dir" or next;
    $transcript{$_} = 1 for grep { !/^\./ && /\.jsonl$/ && !-d "$dir/$_" } readdir $dh;
  }
  return [reverse map {
    my (undef, $ms, $text, $project, $id) = @$_;
    $id = _string($id);
    +{
      timestamp      => defined $ms ? _iso($ms) : undef,
      project        => $project,
      session_id     => $id,
      text           => $text,
      has_transcript => defined $id && $transcript{"$id.jsonl"} ? \1 : \0,
    };
  } @kept];
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

# Claude Code keeps the subagent runs of a session beside its file, in
# <session>/subagents/agent-<agent_id>.jsonl, each with an
# agent-<agent_id>.meta.json next to it; anything else in there is no run.
sub _run_files ($file) {
  $file = path($file);
  my $dir = $file->sibling($file->basename =~ s/\.jsonl\z//r, 'subagents');
  return () unless -d $dir;
  return grep { defined _agent_id($_) } @{$dir->list->to_array};
}

sub _agent_id ($file) {
  return $file->basename =~ /\Aagent-(.+)\.jsonl\z/ ? $1 : undef;
}

# The runs of the run files given, in the order they started, each with the
# cached metadata of its file and, as _file, its path. The metadata cache
# keeps a run file as it keeps a session file, but for its first prompt.
sub _runs ($self, @files) {
  my @runs = map {
    my $meta = $self->_meta($_, 1);
    +{agent_id => _agent_id($_), started_at => $meta->{started_at}, last_activity => $meta->{last_activity},
      messages => $meta->{messages}, _file => $meta->{_file}};
  } @files;
  return _by_time(1, $self->_timed(started_at => 'agent_id', @runs));
}

# The object a run's meta file holds; an empty one if the file is missing or
# holds no object.
sub _run_meta ($self, $file) {
  my $meta = path($file =~ s/\.jsonl\z/.meta.json/r);
  my $bytes = -f $meta ? eval { $meta->slurp } : undef;
  return (defined $bytes ? _record($bytes) : undef) // {};
}

sub _meta ($self, $file, $run = 0) {
  $self->_refresh($file, undef, undef, $run);
  return {%{$self->meta_cache->{"$file"}{meta}}, _file => "$file"};
}

# Brings the cached metadata of $file up to date. The cache keeps the file's
# device, inode, size and mtime, the offset after the last whole line read, the
# scan's state at that offset, and, as ms, the started_at and last_activity of
# the metadata in epoch milliseconds (see _timed). A file that only grew is read
# from that offset on; a new one, or one that shrank, was replaced (another
# inode) or changed without growing, is read from the start. With $visit, a
# file that has to be read at all is read from the start, and $visit sees every
# record of it -- lines before the offset only if the raw test $skip lets them
# through. With $run, $file is a subagent run, whose first prompt the cache
# keeps nowhere: no tool sends it, and it is often a whole briefing of tens of
# KB, which over thousands of runs would be most of what the cache holds.
# Returns whether the file was read.
sub _refresh ($self, $file, $skip = undef, $visit = undef, $run = 0) {
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
      if ($whole) { _absorb(\%state, $rec, $run) }
      else        { _absorb($tail = {%state}, $rec, $run) }
    }
    else {
      return if $skip && $skip->($line);
      $rec = _record($line) or return;
    }
    $visit->($rec) if $visit;
  });

  @fstat = stat $fh;
  my $meta = $self->_summary($file, $tail // \%state);
  $self->meta_cache->{"$file"} = {
    dev    => $fstat[0],
    ino    => $fstat[1],
    size   => $size,
    mtime  => $fstat[9],
    offset => $offset,
    state  => \%state,
    meta   => $meta,
    ms     => {map { $_ => _iso_ms($meta->{$_}) } qw(started_at last_activity)},
  };
  return 1;
}

# A record's sessionId, cwd and timestamp are made into strings by _string, so
# one that is an object or array counts as absent and a later record's fills
# it; the lookups, filters and sorts compare strings only. Of a run ($run), the
# first prompt is not kept; of a session, only what _first_prompt keeps of it.
sub _absorb ($state, $rec, $run = 0) {
  my $timestamp = _string($rec->{timestamp});
  $state->{session_id} //= _string($rec->{sessionId});
  $state->{project}    //= _string($rec->{cwd});
  $state->{branch}     //= $rec->{gitBranch};
  $state->{started}    //= $timestamp;
  $state->{last} = $timestamp if defined $timestamp;

  my $type = $rec->{type} // '';
  $state->{title} = $rec->{aiTitle} if $type eq 'ai-title';

  if ($type eq 'user' || $type eq 'assistant') {
    $state->{count}++;
    $state->{first_prompt} //= _first_prompt(_text($rec->{message})) if $type eq 'user' && !$run;
  }
}

# A session's first prompt as the cache keeps it and list_sessions sends it:
# its first 500 characters, followed by an ellipsis (U+2026) where it is
# longer. A first prompt is often a briefing of many KB, and kept whole it
# would be a large part of what the cache holds; the whole of it is the
# session's first user message, which get_conversation returns. The text is
# decoded, so the cut counts characters and never splits one.
sub _first_prompt ($text) {
  return $text if !defined $text || length $text <= 500;
  return substr($text, 0, 500) . "\x{2026}";
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
# path, so it cannot reach outside the projects dir. If the file of that name
# has to be read at all, it is read once, for its metadata and its entries
# together; the others, which seldom hold the session, only for their
# metadata. Returns the file, and its entries if they were read so; with
# $entries false, they are not read.
sub _file_for_session ($self, $session_id, $entries = 1) {
  my @files = map { _session_files($_) } $self->_project_dirs;
  my $name  = "$session_id.jsonl";
  for my $file ((grep { $_->basename eq $name } @files), (grep { $_->basename ne $name } @files)) {
    my @entries;
    my $visit = $entries && $file->basename eq $name
      ? sub ($rec) { my $entry = _entry($rec) or return; push @entries, $entry }
      : undef;
    my $read  = $self->_refresh($file, undef, $visit);
    next unless ($self->meta_cache->{"$file"}{meta}{session_id} // '') eq $session_id;
    return $file, ($visit && $read ? \@entries : undef);
  }
  return;
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
# or a non-string text, name or content value when the needle could be part of
# a number or boolean stringified (1e5 is "100000", 1e20 "1e+20", 1e999 "Inf",
# true "1"); an object or array becomes no text. A caller that reads its text
# from other values names their tests in @values, as list_prompts does the
# prompt history's display. That text holds none of the markers, so a needle
# kept from the raw test for their sake only has every line decoded there.
sub _raw_skip ($needle, @values) {
  return undef unless $needle =~ /\A[\x20-\x7e]+\z/ && $needle !~ /["\\\[\]]/;
  return undef if grep { index($needle, substr('[tool_use ', $_)) == 0 } 1 .. 9;

  @values = ($TEXT_VALUE, $NAME_VALUE, $CONTENT_VALUE) unless @values;
  my $slash  = index($needle, '/') >= 0;
  my $kelvin = index($needle, 'k') >= 0;
  my $dot_i  = index($needle, 'i') >= 0;
  my $scalar = $needle =~ /\A[0-9efin.+\-]+\z/;
  return sub ($line) {
    return !(index(lc $line, $needle) >= 0
      || (index($line, '\\u') >= 0 && $line =~ $ESCAPE)
      || ($slash  && index($line, '\\/') >= 0)
      || ($kelvin && index($line, "\xE2\x84\xAA") >= 0)
      || ($dot_i  && index($line, "\xC4\xB0") >= 0)
      || ($scalar && grep { $line =~ $_ } @values));
  };
}

# A message's text. Content that is not an array is the text itself: a string
# as it is, a number or boolean as its string, an object as no text; null stays
# undef. Of an array, the text blocks and a marker for each tool_use block
# ("[tool_use]" if its name is missing or empty) and tool_result block; a
# block's text or name is made into a string by _string.
sub _text ($message) {
  return '' unless ref $message eq 'HASH';
  my $content = $message->{content};
  return undef unless defined $content;
  return ref $content eq 'HASH' ? '' : "$content" unless ref $content eq 'ARRAY';

  my @parts;
  for my $block (@$content) {
    next unless ref $block eq 'HASH';
    my $type = $block->{type} // '';
    if    ($type eq 'text')        { push @parts, _string($block->{text}) // '' }
    elsif ($type eq 'tool_use')    {
      my $name = _string($block->{name});
      push @parts, defined $name && length $name ? "[tool_use $name]" : '[tool_use]';
    }
    elsif ($type eq 'tool_result') { push @parts, '[tool_result]' }
  }
  return join "\n", @parts;
}

# A value read as a string -- a block's text or name, a record's sessionId, cwd
# or timestamp: a string as it is, a number or boolean as its string; undef for
# null, an object or an array, which make no text and count as absent.
sub _string ($value) {
  return undef if !defined $value || ref $value eq 'HASH' || ref $value eq 'ARRAY';
  return "$value";
}

sub _snippet ($text, $pos, $len) {
  my $start = $pos - 120 < 0 ? 0 : $pos - 120;
  my $slice = substr $text, $start, $len + 240;
  $slice =~ s/\s+/ /g;
  return $slice;
}

# Whether a session or prompt of $project, of the time $ms (epoch
# milliseconds), passes the project filter of $args and the since and until of
# $range (see _range), both ends included. Without a project, it passes no
# project filter; without a time, it passes since and until.
sub _filtered ($args, $range, $project, $ms) {
  return 0 if defined $args->{project} && !(defined $project && $project eq $args->{project});
  return 1 unless defined $ms;
  my ($since, $until) = @$range;
  return 0 if defined $since && $ms < $since;
  return 0 if defined $until && $ms > $until;
  return 1;
}

# Each record given as [ms, time, then, record]: its time $key (started_at or
# last_activity) in epoch milliseconds (see _iso_ms) and as it is ('' for
# none), and its $then ('' without one). The ms of a session or run, a record
# with a _file, is the one the cache worked out when it read the file; of any
# other record, it is worked out here. No time is parsed in a sort, nor again
# on every call for each of hundreds of sessions; the records get no key.
sub _timed ($self, $key, $then, @recs) {
  my $cache = $self->meta_cache;
  return map {
    my $cached = defined $_->{_file} ? $cache->{$_->{_file}} : undef;
    [$cached ? $cached->{ms}{$key} : _iso_ms($_->{$key}), $_->{$key} // '', defined $then ? $_->{$then} : '', $_];
  } @recs;
}

# The records of entries made by _timed, in the order of their times: oldest
# first with $dir 1, newest first with -1. Times are in the order of the
# instants they are, which their strings are not in where forms mix within a
# second or a time has an offset; of one instant, in that of their strings,
# then by their then. A time that is no instant (none, or no ISO 8601 time)
# counts as the oldest.
sub _by_time ($dir, @timed) {
  my $oldest = -9**9**9;    # -inf
  return map { $_->[3] } sort {
    $dir * (($a->[0] // $oldest) <=> ($b->[0] // $oldest)) || $dir * ($a->[1] cmp $b->[1]) || $a->[2] cmp $b->[2]
  } @timed;
}

# The since and until of $args as epoch milliseconds (see _iso_ms), each undef
# where it is not given; undef where one is given that is no date or time.
sub _range ($args) {
  my ($since, $until) = @$args{qw(since until)};
  $since = _iso_ms($since)    // return undef if defined $since;
  $until = _iso_ms($until, 1) // return undef if defined $until;
  return [$since, $until];
}

# The error result of a tool given a since or until that is no date or time.
sub _no_time ($self, $tool, $args) {
  my ($name) = grep { defined $args->{$_} && !defined _iso_ms($args->{$_}) } qw(since until);
  return $tool->text_result(
    $self->name . ": $name " . to_json($args->{$name}) . ' is not a date (YYYY-MM-DD) or an ISO 8601 time', 1);
}

# An epoch time in milliseconds, as the prompt history holds it, as a whole
# number; undef for a value that is no such number, or one past the year 9999.
sub _ms ($value) {
  $value = _string($value) // return undef;
  return $value =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $value <= 253402300799999 ? int $value : undef;
}

# Such a time in the form Claude Code writes the times of a session file in
# (2026-11-09T19:20:54.499Z, UTC), which sorts as the time does.
sub _iso ($ms) {
  my @t = gmtime int($ms / 1000);
  return sprintf '%04d-%02d-%02dT%02d:%02d:%02d.%03dZ', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0], $ms % 1000;
}

# An ISO 8601 date or time -- a since or until, or a session's time -- in epoch
# milliseconds; undef for anything else, or for a year before 1000. A time is a
# date (YYYY-MM-DD) and, after a T or a space, hours and minutes, with seconds
# or without, with a fraction of any length or without, cut to the millisecond;
# then Z, an offset (+02:00, -0530, +02) or nothing, which is UTC. A date alone
# is the start of that day in UTC, or with $end its last millisecond, so that an
# until of a day takes in all of it. So times written in different forms
# compare as the instants they are, which their strings do not: of
# 2026-11-09T00:00:00.500Z and 2026-11-09T00:00:00Z, the earlier string is the
# later time.
sub _iso_ms ($value, $end = 0) {
  $value = _string($value) // return undef;
  (my ($year, $month, $day, $hour, $min, $sec, $frac, $sign, $off_hour, $off_min) = $value =~ $ISO_TIME)
    or return undef;
  return undef if $year < 1000;    # timegm would read it as an offset from 1900
  my $epoch = eval { timegm($sec // 0, $min // 0, $hour // 0, $day, $month - 1, $year) } // return undef;
  return ($epoch + 86400) * 1000 - 1 if $end && !defined $hour;
  $epoch -= ($sign eq '+' ? 1 : -1) * ($off_hour * 60 + ($off_min // 0)) * 60 if defined $sign;
  return $epoch * 1000 + substr(($frac // '') . '000', 0, 3);
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
C<~/.claude/projects>), and the subagent runs Claude Code keeps beside each
session file (C<< <session_id>/subagents/agent-<agent_id>.jsonl >>, each with an
C<< agent-<agent_id>.meta.json >>), and Claude Code's prompt history,
C<history.jsonl> beside C<projects/>; it offers six tools. A run is no session
of its own: C<list_sessions> and C<list_projects> do not count it.

Session files are read a line at a time. Per-session metadata is cached in
memory together with the file's device, inode, size, modification time and the
offset its scan reached: an unchanged file is not read again, a file that grew
is read only from that offset on, and a file that shrank, was replaced or was
rewritten without growing is read again from the start. A search reads a file
whose metadata is out of date only once, for both. C<get_conversation> reads
the file named after the session (C<< <session_id>.jsonl >>, as Claude Code
names it) first, and the others only if that one does not hold the session;
it too reads that file only once where its metadata is out of date. Run files
are read and cached as session files are, but for a run's first prompt, which
no tool sends and the cache does not keep; a search reads them only when
asked to. The prompt history is not cached: Claude Code appends to it, and
writes it anew when it prunes it, so C<list_prompts> reads it whole, a line at
a time, on every call, and holds no more than C<limit> of its prompts while it
does.

=head2 Tools

=over 2

=item C<list_projects>

C<[{project, dir, sessions, last_activity}]>, newest activity first.

=item C<list_sessions>

Arguments C<project?>, C<since?>, C<until?>, C<limit> (50). Returns
C<[{session_id, project, started_at, last_activity, messages, first_prompt,
title, git_branch}]>, newest first. C<first_prompt> is cut: it holds the first
500 characters of the session's first prompt, followed by C<…> (U+2026) where
the prompt is longer; a prompt of 500 characters or fewer is sent as it is.
The cache keeps no more of it than that. C<get_conversation> returns the whole
prompt, as the session's first user message.

C<since> and C<until> keep the sessions whose C<last_activity> is on or after,
and on or before, an ISO 8601 date or time, compared as instants to the
millisecond. A date (C<2026-11-09>) is that whole day in UTC: from its first
millisecond as C<since>, to its last (C<23:59:59.999>) as C<until>. A time
(C<2026-11-09T10:00:00Z>) has a C<T> or a space after the date, seconds and a
fraction of any length or not, and C<Z>, an offset (C<+02:00>, C<-0530>) or
none, which is UTC; it is the instant it names, included at either end. A
session without a time, or with one that is not such a time, passes both. A
C<since> or C<until> that is not a date or a time is an error result
(C<claude-history: since "VALUE" is not a date (YYYY-MM-DD) or an ISO 8601
time>).

=item C<search_conversations>

Arguments C<query> (required), C<project?>, C<since?>, C<until?>, C<roles>
(C<["user"]>), C<limit> (30), C<include_subagents> (false). Case-insensitive
substring match, snippet ±120 characters. C<project>, C<since> and C<until>
pick the sessions searched, as for C<list_sessions>. With
C<include_subagents>, the subagent runs of each session the filters keep are
searched too: a session's own matches come first, then those of its runs in
the order they started, each carrying the run's C<agent_id> besides the
session's C<session_id> and C<project>. The limit counts them all.

=item C<get_conversation>

Arguments C<session_id> (required), C<offset> (0), C<limit> (50), C<roles>
(C<["user","assistant"]>), C<agent_id?>. Returns
C<< {entries, total, has_more} >>, with C<tool_use> blocks rendered as
C<< [tool_use <name>] >> (C<[tool_use]> for one without a name or with an empty
one) and C<tool_result> as C<[tool_result]>. An entry's C<text> is a string,
or null for a message without content. With C<agent_id>, the messages of that
subagent run of the session, in the same shape; an C<agent_id> that names no
run of the session is an error result (C<claude-history: no subagent run
AGENT_ID in session SESSION_ID>). An unknown session is an empty result, with
C<agent_id> or without.

=item C<list_subagents>

Argument C<session_id> (required). Returns C<[{agent_id, agent_type,
description, started_at, last_activity, messages}]>, one row per subagent run
of the session, in the order the runs started. C<agent_type> and
C<description> come from the run's meta file, null where it is missing or
unreadable; the times and the message count from the run's lines. A session
without runs, and an unknown session, give an empty list.

=item C<list_prompts>

Arguments C<query?>, C<project?>, C<since?>, C<until?>, C<limit> (50). Returns
C<[{timestamp, project, session_id, text, has_transcript}]>, newest first: the
prompts typed into Claude Code, from its prompt history (what the up arrow
recalls), which keeps them after Claude Code has deleted the session's file.
C<text> is the prompt as Claude Code keeps it, whole: text pasted into it is
the placeholder C<[Pasted text #N +M lines]> there, and the pasted contents
themselves are never sent. C<timestamp> is in the form of the other tools'
times (C<2026-11-09T19:20:54.499Z>, UTC), null for a line without a time in
milliseconds, which sorts last; of two prompts of the same time, the later line
comes first. C<query> is a case-insensitive substring match on C<text>, as for
C<search_conversations>; C<project>, C<since> and C<until> filter as for
C<list_sessions>, on the prompt's time. C<has_transcript> is true where a
session file named C<< <session_id>.jsonl >>, as Claude Code names it, is in
a project directory under C<projects/>; it is found from the names of the
files alone, none of them read. A line that is not a JSON object, or holds no
C<display>, is skipped; without the file, the list is empty.

=back

=head1 ATTRIBUTES

L<MCP::Hub::Native::ClaudeHistory> inherits all attributes from L<MCP::Server>
and adds:

=attr root

The Claude configuration directory. Defaults to C<$CLAUDE_CONFIG_DIR> or
C<~/.claude>.

=head1 METHODS

The six tools are also plain methods (C<list_projects>, C<list_sessions>,
C<search_conversations>, C<get_conversation>, C<list_subagents>,
C<list_prompts>) taking an arguments hash reference, so they can be tested without going through the MCP
layer. C<get_conversation> returns undef where its tool answers with the error
for an C<agent_id> that names no run; C<list_sessions>,
C<search_conversations> and C<list_prompts> where theirs answer with the error
for a C<since> or C<until> that is not a date or a time.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Hub::Native::ClaudeSessions>, L<MCP::Server>.

=cut

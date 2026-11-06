package MCP::Hub::Native::ClaudeSessions;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Server', -signatures;

use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json);
use Scalar::Util qw(weaken);

# ABSTRACT: Native MCP server for discovering live Claude Code sessions

has root      => sub { $ENV{CLAUDE_CONFIG_DIR} || ($ENV{HOME} ? "$ENV{HOME}/.claude" : '.claude') };
has proc_root => '/proc';

use constant TAIL_CHUNK => 65536;

sub new ($class, %args) {
  my $self = $class->SUPER::new(name => 'claude-sessions', version => $VERSION, %args);
  $self->instructions('Discover the Claude Code sessions running on this machine.');
  $self->_register;
  return $self;
}

# The tool reaches this server weakly, as MCP::Hub::Native::ClaudeHistory's do.
sub _register ($self) {
  my $gone = $self->name . ': gone, the server of this tool was freed';
  weaken $self;

  $self->tool(
    name         => 'list_running_sessions',
    description  => 'List the Claude Code sessions currently running on this machine',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) {
      return $tool->text_result($gone, 1) unless $self;
      if ($^O ne 'linux' && $self->proc_root eq '/proc') {
        return $tool->text_result('Live session discovery is only supported on Linux', 1);
      }
      return _json($tool, $self->list_running_sessions);
    },
  );
  return $self;
}

sub list_running_sessions ($self) {
  my @sessions;
  for my $pid ($self->_claude_pids) {
    my $cwd = $self->_cwd($pid) // next;
    # A pid read from /proc is text; it goes out as a number.
    my $info = {pid => 0 + $pid, cwd => $cwd, project => $cwd};
    if (my $file = $self->_session_file($cwd)) {
      my $meta = $self->_session_meta($file);
      $info->{$_} = $meta->{$_} for qw(session_id started_at last_activity last_prompt git_branch);
    }
    push @sessions, $info;
  }
  return [sort { $a->{pid} <=> $b->{pid} } @sessions];
}

sub _claude_pids ($self) {
  my $proc = path($self->proc_root);
  my @pids;
  if (-d $proc) {
    for my $entry (@{$proc->list({dir => 1})->to_array}) {
      my $pid = $entry->basename;
      next unless $pid =~ /^\d+$/;
      my $comm = eval { $proc->child($pid, 'comm')->slurp };
      next unless defined $comm;
      chomp $comm;
      push @pids, $pid if $comm eq 'claude';
    }
  }

  # Fallback for the real /proc if the scan turned up nothing.
  if (!@pids && $self->proc_root eq '/proc') {
    my $out = eval { `pgrep -x claude 2>/dev/null` } // '';
    @pids = ($out =~ /(\d+)/g);
  }

  return @pids;
}

sub _cwd ($self, $pid) {
  my $link = path($self->proc_root, $pid, 'cwd');
  my $target = readlink "$link";
  return defined $target ? $target : undef;
}

sub _session_file ($self, $cwd) {
  (my $dirname = $cwd) =~ s{/}{-}g;
  my $dir = path($self->root, 'projects', $dirname);
  return undef unless -d $dir;

  my @files =
    sort { (stat "$b")[9] <=> (stat "$a")[9] }
    grep { $_->basename =~ /\.jsonl$/ } @{$dir->list->to_array};
  return $files[0];
}

# The first sessionId, gitBranch and timestamp come from the head of the file,
# the last timestamp and user prompt from its tail: read forward until the first
# three are known, then backward from the end until the last two are, or until
# the two meet. The result is that of reading every line, whatever the file size.
sub _session_meta ($self, $file) {
  my ($session_id, $started, $last, $branch, $last_prompt);
  my $fh   = path($file)->open('<:raw');
  my $size = (stat $fh)[7];

  while (my $line = <$fh>) {
    chomp $line;
    next unless length $line;
    my $rec = _record($line) or next;
    $session_id //= $rec->{sessionId};
    $branch     //= $rec->{gitBranch};
    $started    //= $rec->{timestamp};
    $last = $rec->{timestamp} if defined $rec->{timestamp};
    $last_prompt = _text($rec->{message}) if ($rec->{type} // '') eq 'user';
    last if defined $session_id && defined $branch && defined $started;
  }

  my ($head, $pos, $buf, $last_found, $prompt_found) = (tell $fh, $size, '');
  while ($pos > $head && !($last_found && $prompt_found)) {
    my $len = $pos - $head < TAIL_CHUNK ? $pos - $head : TAIL_CHUNK;
    $pos -= $len;
    seek $fh, $pos, 0;
    read $fh, (my $chunk), $len;
    $buf = $chunk . $buf;
    next if $pos > $head && index($chunk, "\n") < 0;

    # Every piece but the first is a whole line; so is the first once $pos
    # reached the head.
    my @lines = split /\n/, $buf, -1;
    $buf = $pos > $head ? shift @lines : '';
    for my $line (reverse @lines) {
      next unless length $line;
      my $rec = _record($line) or next;
      if (!$last_found && defined $rec->{timestamp}) { $last = $rec->{timestamp}; $last_found = 1 }
      if (!$prompt_found && ($rec->{type} // '') eq 'user') {
        $last_prompt  = _text($rec->{message});
        $prompt_found = 1;
      }
      last if $last_found && $prompt_found;
    }
  }

  return {
    session_id    => $session_id // $file->basename =~ s/\.jsonl$//r,
    started_at    => $started,
    last_activity => $last // $started,
    last_prompt   => $last_prompt,
    git_branch    => $branch,
  };
}

# The record a line holds: the object it decodes to, or undef for a line that
# is not JSON, or is JSON but not an object ([1], 42, "x").
sub _record ($line) {
  my $rec = eval { decode_json($line) };
  return ref $rec eq 'HASH' ? $rec : undef;
}

# The text blocks of a message; a block that is not an object ("x", 1, [1]) is
# skipped, as MCP::Hub::Native::ClaudeHistory skips it. Content that is not an
# array is the text itself, made into a string as ClaudeHistory makes it: a
# string as it is, a number or boolean as its string, an object as no text;
# null stays undef. A block's text is made into a string as there too.
sub _text ($message) {
  return '' unless ref $message eq 'HASH';
  my $content = $message->{content};
  return undef unless defined $content;
  return ref $content eq 'HASH' ? '' : "$content" unless ref $content eq 'ARRAY';
  return join "\n", map { _string($_->{text}) // '' } grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'text' } @$content;
}

# A text value as a string: a string as it is, a number or boolean as its
# string; undef for null, an object or an array, which make no text.
sub _string ($value) {
  return undef if !defined $value || ref $value eq 'HASH' || ref $value eq 'ARRAY';
  return "$value";
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

  use MCP::Hub::Native::ClaudeSessions;

  my $server = MCP::Hub::Native::ClaudeSessions->new;

=head1 DESCRIPTION

L<MCP::Hub::Native::ClaudeSessions> is a native Perl replacement for live Claude
Code session discovery. Its one tool, C<list_running_sessions>, finds the
C<claude> processes on the machine, reads each one's working directory from
C</proc>, matches it to the newest session file in the history, and reports the
most recent user prompt. Only the head and the tail of a session file are read,
so the call costs the same for a session of any size.

Linux only: on other systems the tool returns an error result saying so.

=head1 ATTRIBUTES

L<MCP::Hub::Native::ClaudeSessions> inherits all attributes from L<MCP::Server>
and adds:

=attr proc_root

The C</proc> directory, overridable for testing. Defaults to C</proc>.

=attr root

The Claude configuration directory, as for L<MCP::Hub::Native::ClaudeHistory>.

=head1 METHODS

=method list_running_sessions

The tool as a plain method. Returns
C<[{pid, cwd, project, session_id, started_at, last_activity, last_prompt,
git_branch}]>, with C<pid> a number.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Hub::Native::ClaudeHistory>.

=cut

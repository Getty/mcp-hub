package MCP::Hub::Native::ClaudeSessions;
our $VERSION = '0.001';
use Mojo::Base 'MCP::Server', -signatures;

use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json);

# ABSTRACT: Native MCP server for discovering live Claude Code sessions

has root      => sub { $ENV{CLAUDE_CONFIG_DIR} || ($ENV{HOME} ? "$ENV{HOME}/.claude" : '.claude') };
has proc_root => '/proc';

sub new ($class, %args) {
  my $self = $class->SUPER::new(name => 'claude-sessions', version => $VERSION, %args);
  $self->instructions('Discover the Claude Code sessions running on this machine.');
  $self->_register;
  return $self;
}

sub _register ($self) {
  $self->tool(
    name         => 'list_running_sessions',
    description  => 'List the Claude Code sessions currently running on this machine',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) {
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
    my $info = {pid => $pid, cwd => $cwd, project => $cwd};
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

sub _session_meta ($self, $file) {
  my ($session_id, $started, $last, $branch, $last_prompt);
  for my $line (split /\n/, path($file)->slurp) {
    next unless length $line;
    my $rec = eval { decode_json($line) } or next;
    $session_id //= $rec->{sessionId};
    $branch     //= $rec->{gitBranch};
    $started    //= $rec->{timestamp};
    $last = $rec->{timestamp} if defined $rec->{timestamp};
    $last_prompt = _text($rec->{message}) if ($rec->{type} // '') eq 'user';
  }
  return {
    session_id    => $session_id // $file->basename =~ s/\.jsonl$//r,
    started_at    => $started,
    last_activity => $last // $started,
    last_prompt   => $last_prompt,
    git_branch    => $branch,
  };
}

sub _text ($message) {
  return '' unless ref $message eq 'HASH';
  my $content = $message->{content};
  return $content unless ref $content eq 'ARRAY';
  return join "\n", map { $_->{text} // '' } grep { ($_->{type} // '') eq 'text' } @$content;
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
most recent user prompt.

Linux only: on other systems the tool returns an error result saying so.

=head2 list_running_sessions

Returns C<[{pid, cwd, project, session_id, started_at, last_activity,
last_prompt, git_branch}]>.

=head1 ATTRIBUTES

L<MCP::Hub::Native::ClaudeSessions> inherits all attributes from L<MCP::Server>
and adds:

=attr proc_root

The C</proc> directory, overridable for testing. Defaults to C</proc>.

=attr root

The Claude configuration directory, as for L<MCP::Hub::Native::ClaudeHistory>.

=head1 METHODS

=method list_running_sessions

The tool as a plain method, returning the array reference described above.

=head1 SEE ALSO

L<MCP::Hub>, L<MCP::Hub::Native::ClaudeHistory>.

=cut

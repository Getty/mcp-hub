package ForkProbe;
use Mojo::Base 'EchoServer', -signatures;

use POSIX ();

# The echo server with what the fork tests look at from inside a worker. Only
# `class` entries mount it -- it is never run over stdio.

sub new ($class, @args) {
  my $self = $class->SUPER::new(@args);

  # Who answers: the worker's pid, its parent's and its process name.
  $self->tool(
    name         => 'whoami',
    description  => 'The pid, parent pid and $0 of the process that answers',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) { return $tool->structured_result({pid => $$, ppid => getppid, name => $0, server => $self->name}) },
  );

  # Counts the calls this process has answered, to tell the order they arrived in.
  my $seq = 0;
  $self->tool(
    name         => 'seq',
    description  => 'The number of this call among those the process answered, and its pid',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) { return $tool->structured_result({seq => ++$seq, pid => $$}) },
  );

  # The worker kills itself. A tool that merely dies is answered by MCP::Server
  # with a JSON-RPC error, so it is no crash.
  $self->tool(
    name         => 'crash',
    description  => 'Kill the process that answers, with SIGKILL',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) { kill KILL => $$; sleep 5; return $tool->text_result('not reached') },
  );

  # Blocks the whole process, event loop included, unlike `sleep`.
  $self->tool(
    name         => 'block',
    description  => 'Block the process for the given seconds, without serving anything',
    input_schema => {type => 'object', properties => {seconds => {type => 'number'}}},
    code         => sub ($tool, $args) {
      my $seconds = $args->{seconds} // 1;
      select undef, undef, undef, $seconds;
      return $tool->text_result("blocked $seconds");
    },
  );

  # Reads from a file descriptor the process inherited, by number, and reports
  # where the descriptor ended up -- for the fork tests' look at shared offsets.
  $self->tool(
    name         => 'readfd',
    description  => 'Read bytes from an inherited file descriptor',
    input_schema => {type => 'object', properties => {fd => {type => 'integer'}, bytes => {type => 'integer'}}},
    code         => sub ($tool, $args) {
      my $fd   = $args->{fd};
      my $read = POSIX::read($fd, my $buf, $args->{bytes} // 1) // return $tool->text_result("read $fd: $!", 1);
      return $tool->structured_result({text => $buf, pos => POSIX::lseek($fd, 0, POSIX::SEEK_CUR()) + 0});
    },
  );

  return $self;
}

# `echo` with the extras the facade must carry through: a title and _meta.
sub _handle_tools_list ($self, $context) {
  my ($result, @hints) = $self->SUPER::_handle_tools_list($context);
  for my $tool (grep { $_->{name} eq 'echo' } @{$result->{tools}}) {
    $tool->{title} = 'Echo';
    $tool->{_meta} = {'anthropic/maxResultSizeChars' => 1234};
  }
  return ($result, @hints);
}

1;

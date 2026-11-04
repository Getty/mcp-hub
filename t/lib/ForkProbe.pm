package ForkProbe;
use Mojo::Base 'EchoServer', -signatures;

# The echo server with what the fork tests look at from inside a worker. Only
# `class` entries mount it -- it is never run over stdio.

sub new ($class, @args) {
  my $self = $class->SUPER::new(@args);

  # Who answers: the worker's pid, its parent's and its process name.
  $self->tool(
    name         => 'whoami',
    description  => 'The pid, parent pid and $0 of the process that answers',
    input_schema => {type => 'object'},
    code         => sub ($tool, $args) { return $tool->structured_result({pid => $$, ppid => getppid, name => $0}) },
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

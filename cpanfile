requires 'perl' => '5.020';

requires 'CryptX';           # Crypt::Misc::slow_eq, Crypt::PRNG::random_bytes
requires 'IO::Socket::SSL' => '2.009';  # TLS: https url upstreams, an https hub.listen
requires 'MCP'          => '0.15';
requires 'Mojolicious'  => '9.49';
requires 'YAML::PP';         # .yml/.yaml configuration files

# YAML::PP is loaded on demand, only when a YAML config is actually read, but
# it is a hard requirement all the same so that a .yml never fails on a fresh
# install. Everything else the hub uses (Digest::SHA, Exporter, JSON::PP,
# IPC/socketpair, Socket, POSIX, Scalar::Util, Time::HiRes) is core.

on test => sub {
  requires 'Test::More';
  # Test::Mojo ships with Mojolicious.
};

# MCP loads JSON::Schema::Tiny, which loads strictures when AUTHOR_TESTING is
# set - and dzil test sets it.
on develop => sub {
  requires 'strictures', '2';
};

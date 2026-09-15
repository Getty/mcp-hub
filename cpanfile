requires 'perl' => '5.020';

requires 'MCP'          => '0.15';
requires 'Mojolicious'  => '9.0';
requires 'CryptX';           # Crypt::Misc::slow_eq, Crypt::PRNG::random_bytes

# Everything else the hub uses (Digest::SHA, IPC/socketpair, Socket, POSIX,
# List::Util, Scalar::Util, File::Spec, File::Path, Time::Local) is core.

on test => sub {
  requires 'Test::More';
  # Test::Mojo ships with Mojolicious.
};

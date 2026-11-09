requires 'perl' => '5.020';

requires 'CryptX';           # Crypt::Misc::slow_eq, Crypt::PRNG::random_bytes
requires 'IO::Socket::SSL' => '2.009';  # TLS: https url upstreams, an https hub.listen
requires 'JSON::MaybeXS' => '1.004006';  # brings Cpanel::JSON::XS, see below
requires 'MCP'          => '0.15';
requires 'Mojolicious'  => '9.49';
requires 'YAML::PP';         # .yml/.yaml configuration files

# JSON::MaybeXS is here for Cpanel::JSON::XS: wherever its install finds a C
# compiler, it requires Cpanel::JSON::XS (4.38 or later on perl 5.36+, since
# 1.004006), and it falls back to JSON::PP on a host without one. The natives
# decode session files through it, and Mojo::JSON goes XS by itself once
# Cpanel::JSON::XS 4.20+ is installed. In pure Perl, a cold read of a large
# Claude Code history takes seconds of CPU instead of a fraction of one.
#
# YAML::PP is loaded on demand, only when a YAML config is actually read, but
# it is a hard requirement all the same so that a .yml never fails on a fresh
# install. Everything else the hub uses (Digest::SHA, Exporter, JSON::PP,
# IPC/socketpair, Socket, POSIX, Scalar::Util, Time::HiRes, Time::Local) is
# core.

on test => sub {
  requires 'Test::More';
  # Test::Mojo ships with Mojolicious.
};

# MCP loads JSON::Schema::Tiny, which loads strictures when AUTHOR_TESTING is
# set - and dzil test sets it.
on develop => sub {
  requires 'strictures', '2';
};

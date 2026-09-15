use Mojo::Base -strict;
use Test::More;

my @modules = qw(
  MCP::Hub
  MCP::Hub::Config
  MCP::Hub::Manifest
  MCP::Hub::Auth
  MCP::Hub::Facade
  MCP::Hub::Facade::Server
  MCP::Hub::Facade::Tool
  MCP::Hub::Aggregate
  MCP::Hub::Upstream
  MCP::Hub::Upstream::Perl
  MCP::Hub::Upstream::Stdio
  MCP::Hub::Native::ClaudeHistory
  MCP::Hub::Native::ClaudeSessions
  MCP::Hub::Native::Status
  MCP::Hub::Command::daemon
  MCP::Hub::Command::config
  MCP::Hub::Command::status
  MCP::Hub::Command::refresh
  MCP::Hub::Command::token
);

use_ok($_) for @modules;

done_testing;

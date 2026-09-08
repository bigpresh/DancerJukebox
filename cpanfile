# Runtime dependencies. Carp, Digest::MD5, File::Path and File::Spec are core,
# so they're not listed here.

requires 'Dancer';
requires 'Dancer::Plugin::Database';
requires 'Dancer::Plugin::MPD';
requires 'Audio::MPD';              # used via Dancer::Plugin::MPD
requires 'DateTime';
requires 'Template';                # the template_toolkit engine in config.yml
requires 'DBD::SQLite';             # default database driver

# Only needed by bin/queue-watcher, the older daemonisation approach that
# jukebox-queuerunner replaced. Not installed here, so that script won't
# currently run.
requires 'Proc::PID::File';

on test => sub {
    requires 'Test::More';
};

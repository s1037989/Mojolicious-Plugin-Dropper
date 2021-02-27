package Mojolicious::Command::dropper;
use Mojo::Base 'Mojolicious::Command';

use Mojo::Server::Daemon;
use Mojo::Util qw(getopt);

our $VERSION = '0.01';

has description => 'Quickly serve static files';
has usage => sub { shift->extract_usage };

sub run {
  my ($self, @args) = @_;

  my $app = Mojolicious->new;
  my $daemon = Mojo::Server::Daemon->new(app => $app);
  getopt(\@args,
    'b|backlog=i'  => sub { $daemon->backlog($_[1]) },
    'c|clients=i'  => sub { $daemon->max_clients($_[1]) },
    'i|inactivity-timeout=i' => sub { $daemon->inactivity_timeout($_[1]) },
    'l|listen=s'   => \my @listen,
    'p|proxy'      => sub { $daemon->reverse_proxy(1) },
    'r|requests=i' => sub { $daemon->max_requests($_[1]) },
    'C|cleanup'    => \my $cleanup,
    'D|default=s'  => \my $default,
    'P|pastes:s'   => \my $pastes,
    'Q|qrcodes'    => \my $qrcodes,
    'U|uploads:s'  => \my $uploads
  );

  #$app->plugin(Config => {default => {}});
  $app->plugin('Dropper' => {
    paths => [@args],
    cleanup => $cleanup,
    default => $default,
    pastes  => $pastes,
    qrcodes => $qrcodes,
    uploads => $uploads,
  });

  $daemon->listen(\@listen) if @listen;
  $daemon->run;
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Command::static - Quickly serve static files

=head1 SYNOPSIS

  Usage: APPLICATION static [OPTIONS] dir1 dir2 ... file1 file2 ...

    ./myapp.pl static .
    ./myapp.pl static -d file2 -l http://*:8080 .

  Options:
    -b, --backlog <size>                 Listen backlog size, defaults to
                                         SOMAXCONN
    -c, --clients <number>               Maximum number of concurrent
                                         connections, defaults to 1000
    -d, --default <file>                 Default file to respond with (like
                                         index.html). Defaults to directory
                                         index listing.
    -h, --help                           Show this summary of available options
        --home <path>                    Path to home directory of your
                                         application, defaults to the value of
                                         MOJO_HOME or auto-detection
    -i, --inactivity-timeout <seconds>   Inactivity timeout, defaults to the
                                         value of MOJO_INACTIVITY_TIMEOUT or 15
    -l, --listen <location>              One or more locations you want to
                                         listen on, defaults to the value of
                                         MOJO_LISTEN or "http://*:3000"
    -m, --mode <name>                    Operating mode for your application,
                                         defaults to the value of
                                         MOJO_MODE/PLACK_ENV or "development"
    -p, --proxy                          Activate reverse proxy support,
                                         defaults to the value of
                                         MOJO_REVERSE_PROXY
    -r, --requests <number>              Maximum number of requests per
                                         keep-alive connection, defaults to 100
                                         
=head1 DESCRIPTION

L<Mojolicious::Command::static> quickly serves static files

Serves files from the current directory as well as those specified on the
command line. If no default file is specified, a directory index will be built.

The maximum file size can be specified by the STATIC_MAXSIZE environment
variable, or 10G by default.

=head1 ATTRIBUTES

L<Mojolicious::Command::static> inherits all attributes from
L<Mojolicious::Command> and implements the following new ones.

=head2 description

  my $description = $static->description;
  $static         = $static->description('Foo');

Short description of this command, used for the command list.

=head2 usage

  my $usage = $static->usage;
  $routes   = $static->usage('Foo');

Usage information for this command, used for the help screen.

=head1 METHODS

L<Mojolicious::Command::static> inherits all methods from
L<Mojolicious::Command> and implements the following new ones.

=head2 run

  $static->run(@ARGV);

Run this command.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut

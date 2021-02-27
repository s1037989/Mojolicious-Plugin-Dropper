package Mojolicious::Plugin::Dropper;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::File qw(curfile path tempdir tempfile);
use Mojo::Util qw(decamelize getopt);

use File::Basename qw(dirname);
use List::MoreUtils 'uniq';

# Since this is generally a temporary execution to easily setup a file
# transfer, allow extremely large files;
use constant MAX_SIZE => $ENV{DROPPER_MAXSIZE} || 10_000_000_000;

has [qw(app qrcodes)];

has [qw(_downloader _paster _uploader)];
has '_index' => sub { [] };

sub register ($self, $app, $config) {
  $self->app($app);

  # Log requests for static files
  $app->hook(after_static => sub ($c) {
    $c->log->info(sprintf 'GET %s', $c->req->url->path);
  });

  $app->static->paths(_static_paths(curfile->sibling->child('dropper', 'resources', 'public')));
  $app->renderer->paths(_static_paths(curfile->sibling->child('dropper', 'resources', 'templates')));

  $app->max_request_size(MAX_SIZE);

  $self->qrcodes($config->{qrcodes});

  $self->downloader($config->{paths}, $config->{default});
  $self->uploader($config->{uploads}) if defined $config->{uploads};
  $self->paster($config->{pastes}) if defined $config->{pastes};
  $self->dropper;
  return $self;
}

sub dropper ($self) {
  my $app = $self->app;
  $app->routes->get('/dropper')->to(
    downloader => $self->_downloader,
    paster => $self->_paster,
    uploader => $self->_uploader,
  );
}

sub downloader ($self, $paths=[], $default='') {
  my $app = $self->app;

  # Add all the paths and paths of filenames specified on the command line
  push @{$app->static->paths}, @$paths;

  $app->helper(file_index => sub { $self->_file_index });

  # Build an index of the available specified files
  my @files = $app->file_index;
  $app->log->info(sprintf '%d files', scalar @files);
  my $r;
  if ( $default ) {
    $app->log->info("downloader index $default");
    $r = $app->routes
             ->get('/')
             ->to(qrcodes => $self->qrcodes, cb => sub { shift->reply->static($default) })
             ->name('downloader');
  } else {
    $app->log->info('downloader index directory listing');
    $r = $app->routes
             ->get('/')
             ->to(qrcodes => $self->qrcodes)
             ->name('downloader');
  }
  $app->log->info(sprintf 'downloader URL: %s', $r->to_string);
  $self->_downloader('downloader');
}

sub paster ($self, $pastes) {
  my $app = $self->app;
  $pastes ||= tempdir(CLEANUP => 1) if !$pastes;
  $pastes = path($pastes) if !ref $pastes;
  push @{$app->static->paths}, $pastes;
  my $r = $app->routes->get('/dropper/paster')->name('paster');
  $app->routes->post('/dropper/paste' => sub ($c) {
    my $url;
    if ( my $paste = $c->param('paste') ) {
      my $save = tempfile(DIR => $pastes, UNLINK => 0)->spurt($paste);
      $c->log->info("paste $save");
      $url = $c->url_for($save) if $self->qrcodes;
      $url = "https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=$url" if $url;
    }
    $c->render(json => {ok => 1, url => $url});
  })->name('paste');
  $app->log->info(sprintf 'paster URL: %s', $r->to_string);
  $self->_paster('paster');
}

sub uploader ($self, $uploads) {
  my $app = $self->app;
  $uploads ||= tempdir(CLEANUP => 1) if !$uploads;
  $uploads = path($uploads) if !ref $uploads;
  push @{$app->static->paths}, $uploads;
  $app->log->info("uploads to $uploads");
  my $r = $app->routes->get('/dropper/uploader')->to(qrcodes => $self->qrcodes)->name('uploader');
  $app->routes->post('/dropper/upload' => sub ($c) {
    my $url;
    if ( my $file = $c->req->upload('file') ) {
      my $save = $uploads->child($file->filename);
      $file->move_to($save);
      $c->log->info("upload $save");
      $self->_index->[0] = 0;
      $url = $c->url_for($save->basename)->to_abs if $c->param('qrcodes');
      $url = "https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=$url" if $url;
    }
    $c->render(json => {ok => 1, url => $url});
  })->name('upload');
  $app->log->info(sprintf 'uploader URL: %s', $r->to_string);
  $self->_uploader('uploader');
}

sub _file_index ($self) {
  my ($time, $files) = $self->_index->@*;
  $time ||= 0;
  return @$files if time - $time < 60;
  $files = [];
  foreach my $path ( uniq map { path($_) } grep { $_ && -e $_ } ($self->app->static->paths->@[1, -1]) ) {
    if ( -d $path ) {
      $path->list_tree->each(sub{
        push @$files, $_->to_rel($path);
      });
    } else {
      push @$files, $path;
    }
  }
  $self->_index([time, $files]);
  return @$files;
}

sub _static_paths {
  [uniq grep { -d $_ } map { -f $_ ? dirname "$_" : "$_" } @_]
}

1;
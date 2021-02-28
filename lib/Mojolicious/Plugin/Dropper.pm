package Mojolicious::Plugin::Dropper;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::Collection qw(c);
use Mojo::File qw(curfile path tempdir tempfile);
use Mojo::Util qw(decamelize getopt);

use File::Basename qw(dirname);
use List::MoreUtils 'uniq';

# Since this is generally a temporary execution to easily setup a file
# transfer, allow extremely large files;
use constant MAX_SIZE => $ENV{DROPPER_MAXSIZE} || 10_000_000_000;

has 'app';
has cleanup => 1;
has qrcodes => 0;

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

  $self->cleanup($config->{cleanup});
  $self->qrcodes($config->{qrcodes});

  $self->uploader($config->{uploads}) if defined $config->{uploads};
  $self->paster($config->{pastes}) if defined $config->{pastes};
  $self->downloader($config->{paths}, $config->{default}) if defined $config->{downloads};
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
  my $r;
  if ($default) {
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
  $pastes ||= tempdir(CLEANUP => $self->cleanup) if !$pastes;
  $pastes = path($pastes) if !ref $pastes;
  push @{$app->static->paths}, $pastes;
  $pastes = $pastes->child('pastes')->make_path;
  $app->log->info("pastes to $pastes");
  my $r = $app->routes->get('/dropper/paster')->to(qrcodes => $self->qrcodes)->name('paster');
  $app->routes->post('/dropper/paste' => sub ($c) {
    my $save;
    my $url;
    if ( my $paste = $c->param('paste') ) {
      $save = tempfile(DIR => $pastes, UNLINK => 0)->spurt($paste);
      $c->log->info("paste $save");
      $self->_index->[0] = 0;
      $url = $c->url_for($save->to_rel($pastes->dirname))->to_abs;
      $url = "https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=$url" if $url;
    }
    $c->render(json => {ok => 1, url => $url, filename => $save->basename, size => $save->stat->size});
  })->name('paste');
  $app->log->info(sprintf 'paster URL: %s', $r->to_string);
  $self->_paster('paster');
}

sub uploader ($self, $uploads) {
  my $app = $self->app;
  $uploads ||= tempdir(CLEANUP => $self->cleanup) if !$uploads;
  $uploads = path($uploads) if !ref $uploads;
  push @{$app->static->paths}, $uploads;
  $uploads = $uploads->child('uploads')->make_path;
  $app->log->info("uploads to $uploads");
  my $r = $app->routes->get('/dropper/uploader')->to(qrcodes => $self->qrcodes)->name('uploader');
  $app->routes->post('/dropper/upload' => sub ($c) {
    my $save;
    my $url;
    if ( my $file = $c->req->upload('file') ) {
      $save = $uploads->child($file->filename);
      $file->move_to($save);
      $c->log->info("upload $save");
      $self->_index->[0] = 0;
      $url = $c->url_for($save->to_rel($uploads->dirname))->to_abs;
      $url = "https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=$url" if $url;
    }
    $c->render(json => {ok => 1, url => $url, filename => $save->basename});
  })->name('upload');
  $app->log->info(sprintf 'uploader URL: %s', $r->to_string);
  $self->_uploader('uploader');
}

sub _file_index ($self) {
  my ($time, $files) = $self->_index->@*;
  $time ||= 0;
  $self->app->log->info(sprintf 'Cached: %d files', scalar @$files) and return @$files if time - $time < 60;
  $files = [];
  c($self->app->static->paths->@*)
    ->grep(sub{ $_ && -e $_ })
    ->map(sub { path($_) })
    ->uniq
    ->tail(-1)
    ->each(sub {
      my $path = $_;
      if ( -d $path ) {
        $path->list_tree->each(sub{
          push @$files, $_->to_rel($path);
        });
      } else {
        push @$files, $path;
      }
    });
  $self->_index([time, $files]);
  $self->app->log->info(sprintf 'Fresh: %d files', scalar @$files) and return @$files;
}

sub _static_paths {
  [uniq grep { -d $_ } map { -f $_ ? dirname "$_" : "$_" } @_]
}

1;
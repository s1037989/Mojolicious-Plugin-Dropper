package Mojolicious::Plugin::Dropper;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::Collection qw(c);
use Mojo::File qw(curfile path tempdir tempfile);
#use Mojo::Util qw(decamelize getopt);

use File::Basename qw(dirname);
use List::MoreUtils qw(uniq);

# Since this is generally a temporary execution to easily setup a file
# transfer, allow extremely large files;
use constant MAX_SIZE => $ENV{DROPPER_MAXSIZE} || 10_000_000_000;

has 'app';
has cleanup => 1;

sub register ($self, $app, $config) {
  $self->app($app);

  # Log requests for static files
  $app->hook(after_static => sub ($c) {
    $c->log->info(sprintf 'GET %s', $c->req->url->path);
  });

  $app->hook(before_render => sub ($c, $args) {
    # Make sure we are rendering the exception template
    return unless my $template = $args->{template};
    return unless $template eq 'exception';
    return unless $c->app->mode eq 'development' && $c->req->headers->user_agent eq 'Mojolicious (Perl)';
    $args->{text} = sprintf '%s: %s', $args->{status}, $c->stash($template);
  });
  
  $app->hook(after_dispatch => sub ($c) {
    if (my $info = $c->stash('info')) {
      $c->log->info($info);
    }
  });

  $app->helper('reply.not_found_msg' => sub ($c, $msg) {
    $c->log->info($msg);
    $c->stash(msg => $msg);
    $c->reply->not_found;
  });

  $self->static_paths(static => curfile->sibling->child('dropper', 'resources', 'public'));
  $self->static_paths(renderer => curfile->sibling->child('dropper', 'resources', 'templates'));

  $app->max_request_size(MAX_SIZE);

  my $r = $app->routes;
  $r->add_type(zones => [keys %{$app->config->{zones}}]);

  $config->{mount} ||= '/dropper';
  my $dropper = $app->routes->under($config->{mount} => sub { $self->authen(shift) });
  $dropper->under('/' => sub { $self->zone_index(shift) })->get('/' => {zonename => '', zone => {}, zones => $app->config->{zones}})->name('dropper');
  my $zone = $dropper->under('/<zonename:zones>' => sub { $self->authz(shift) });

  $self->uploader($zone);
  $self->paster($zone);
  $self->downloader($zone);

  my $defaultzonename = $app->config->{defaultzone};
  my $defaultzone = $app->config->{zones}->{$defaultzonename};
  $dropper->get('/*file')->to(zonename => $defaultzonename, zone => $defaultzone, cb => sub { $self->defaultdownloader(shift) })->name('defaultdownloader') if $defaultzone;

  return $self;
}

sub zone_index ($self, $c) {
  return 1 if $c->stash('user');
  $self->reject_authen($c);
  return undef;
}

sub authen ($self, $c) {
  my $app = $self->app;
  return 1 unless $app->config->{login};
  my $userinfo = $c->req->url->to_abs->userinfo or return 1;
  my ($user) = split /:/, $userinfo;
  foreach my $login (@{$app->config->{login}}) {
    return $c->stash(user => $user, layout => 'dropper') if $userinfo eq $login;
  }
  return 1;
}

sub reject_authen ($self, $c) {
  my $user = $c->stash('user') || 'anonymous';
  $c->res->headers->www_authenticate('Basic');
  $c->render(text => "$user authentication failed", status => 401, info => "$user authentication failed");
}

sub authz ($self, $c) {
  my $app = $self->app;
  my $zonename = $c->param('zonename');
  my $zone = $app->config->{zones}->{$zonename};
  $c->stash(zonename => $zonename, zone => $zone);
  my $user = $c->stash('user');
  $c->stash(authz => 1) if grep { defined $user && $_ eq $user } @{$zone->{login}};
  return 1;
}

sub reject_authz ($self, $c) {
  my $user = $c->stash('user');
  $c->render(text => "$user unauthorized", status => 403, info => "$user unauthorized");
}

sub defaultdownloader ($self, $c) {
  my $zonename = $c->stash('zonename');
  my $zone = $c->stash('zone');
  my $path = path($zone->{path})->make_path;
  my $file = $path->child($c->param('file')) if $zone->{downloads} // 1;
  if (my $file = $c->param('file')) {
    $file = $path->child($file);
    return $c->reply->not_found_msg("$zonename requested $file not found") unless -f $file;
    $c->stash(info => "$zonename serving requested $file");
    $c->reply->file($file);
  }
  else {
    $c->reply->not_found;
  }
};

sub downloader ($self, $r) {
  my $app = $self->app;

  $r->get("/*file" => {file => ''})->to(cb => sub ($c) {
    my $zonename = $c->stash('zonename');
    my $zone = $c->stash('zone');
    my $path = path($zone->{path})->make_path;
    my $file = $path->child($c->param('file')) if $zone->{downloads} // 1;
    if (my $file = $c->param('file')) {
      $file = $path->child($file);
      return $c->reply->not_found_msg("$zonename requested $file not found") unless -f $file;
      $c->stash(info => "$zonename serving requested $file");
      return $c->reply->file($file);
    }
    return $self->reject_authz($c) unless $c->stash('authz');
    my $default = path($zone->{path}, $zone->{default}) if $zone->{default};
    if (-f $default) {
      $c->stash(info => "$zonename serving default $default");
      $c->reply->file($default);
    }
    else {
      my $files = $path->list_tree
        ->map('to_rel', $zone->{path})
        ->grep(sub{$zone->{downloads} // 1 ? $_ : 0})
        ->grep(sub{$zone->{pastes} // 1 ? $_->to_array->[0] ne 'pastes' : 1})
        ->grep(sub{$zone->{uploads} // 1 ? $_->to_array->[0] ne 'uploads' : 1});
      $c->stash(files => $files, info => "$zonename serving requested directory listing for $path");
    }
  })->name('downloader');
}

sub paster ($self, $r) {
  my $app = $self->app;

  $r->get("/pastes/#file" => {file => ''})->to(cb => sub ($c) {
    my $zonename = $c->stash('zonename');
    my $zone = $c->stash('zone');
    return $c->reply->not_found_msg("pastes disabled for $zonename") unless $zone->{pastes} // 1;
    my $path = path($zone->{path}, 'pastes')->make_path;
    if (my $file = $c->param('file')) {
      $file = $path->child($file);
      return $c->reply->not_found_msg("$zonename requested $file not found") unless -f $file;
      return $c->render(text => $file->slurp, info => "$zonename serving requested $file");
    }
    return $self->reject_authz($c) unless $c->stash('authz');
    my $files = $path->list_tree->map('to_rel', $zone->{path})->map('basename');
    $c->stash(files => $files, info => "$zonename serving requested pastes listing for $path");
  })->name('paster');
  
  $r->post("/paste" => sub ($c) {
    return $self->reject_authz($c) unless $c->stash('authz');
    my $zonename = $c->stash('zonename');
    my $zone = $c->stash('zone');
    return $c->reply->not_found_msg("pastes disabled for $zonename") unless $zone->{pastes} // 1;
    my $path = path($zone->{path}, 'pastes')->make_path;
    if (my $paste = $c->req->upload('file') || $c->param('paste')) {
      my $save = ref $paste
        ? $paste->move_to($path->child($paste->filename))
        : tempfile(DIR => $path, UNLINK => 0)->spurt($paste);
      my $url = $c->url_for($save->to_rel($path->dirname))->to_abs;
      $url = "https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=$url" if $url;
      $c->render(
        info => "$zonename paste $save",
        json => {ok => 1, url => $url, filename => $save->basename, size => $save->stat->size},
      );
    }
    else {
      $c->reply->json_not_found;
    }
  })->name('paste');
}

sub uploader ($self, $r) {
  my $app = $self->app;

  $r->get("/uploads/#file" => {file => ''})->to(cb => sub ($c) {
    my $zonename = $c->stash('zonename');
    my $zone = $c->stash('zone');
    return $c->reply->not_found_msg("uploads disabled for $zonename") unless $zone->{uploads} // 1;
    my $path = path($zone->{path}, 'uploads')->make_path;
    if (my $file = $c->param('file')) {
      $file = $path->child($file);
      return $c->reply->not_found_msg("$zonename requested $file not found") unless -f $file;
      $c->stash(info => "$zonename serving requested $file");
      if ($c->param('delete')) {
        return $self->reject_authz($c) unless $c->stash('authz');
	      $file->remove;
      }
      else {
        return $c->reply->file($file);
      }
    }
    return $self->reject_authz($c) unless $c->stash('authz');
    my $files = $path->list_tree->map('to_rel', $zone->{path})->map('basename');
    $c->stash(files => $files, info => "$zonename serving requested uploads listing for $path");
  })->name('uploader');
  
  $r->post("/upload" => sub ($c) {
    return $self->reject_authz($c) unless $c->stash('authz');
    my $zonename = $c->stash('zonename');
    my $zone = $c->stash('zone');
    return $c->reply->not_found_msg("uploads disabled for $zonename") unless $zone->{uploads} // 1;
    my $path = path($zone->{path}, 'uploads')->make_path;
    if (my $file = $c->req->upload('file')) {
      my $save = $file->move_to($path->child($file->filename));
      my $url = $c->url_for($save->to_rel($path->dirname))->to_abs;
      $url = "https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=$url" if $url;
      $c->render(
        info => "$zonename upload $save",
        json => {ok => 1, url => $url, filename => $save->basename, size => $save->stat->size},
      );
    }
    else {
      $c->reply->json_not_found;
    }
  })->name('upload');
}

sub static_paths ($self, $name, @paths) {
  my $app = $self->app;
  unshift @{$app->$name->paths}, uniq grep { -d $_ } map { -f $_ ? dirname "$_" : "$_" } @paths;
  return $self;
}

1;

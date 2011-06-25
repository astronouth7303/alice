package Alice::Role::Assetdir;

use Any::Moose 'Role';
use File::ShareDir qw/dist_dir/;
use FindBin;

has assetdir => (
  is => 'ro',
  default => sub {
    my $bin = $FindBin::Bin;
    -e "$bin/../share/static" ? "$bin/../share" : dist_dir('App-Alice');
  }
);

has configdir => (
  is => 'ro',
  default => "$ENV{HOME}/.alice",
);

has logdir => (
  is => 'ro',
  lazy => 1,
  default => sub {
    $_[0]->configdir."/logs";
  } 
);

1;

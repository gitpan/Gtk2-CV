package Gtk2::CV;

use XSLoader;

$VERSION = 0.1;

XSLoader::load "Gtk2::CV", $VERSION;

use Gtk2;

sub require_image {
   my $path;

   for (@INC) {
      $path = "$_/Gtk2/CV/images/$_[0]";
      last if -r $path;
   }

   eval { new_from_file Gtk2::Gdk::Pixbuf $path }
      or die "can't find image $_[0] in \@INC";
}

1;


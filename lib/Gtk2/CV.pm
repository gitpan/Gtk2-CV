package Gtk2::CV;

use Gtk2;
use Glib;

use IO::AIO;

BEGIN {
   use XSLoader;

   $VERSION = '1.1';

   XSLoader::load "Gtk2::CV", $VERSION;
}

my $aio_source;

# we use a low priority to give GUI interactions as high a priority
# as possible.
sub enable_aio {
   $aio_source ||=
      add_watch Glib::IO IO::AIO::poll_fileno,
                         in => sub { IO::AIO::poll_cb; 1 },
                         undef,
                         &Glib::G_PRIORITY_LOW;
}

sub disable_aio {
   remove Glib::Source $aio_source if $aio_source;
   undef $aio_source;
}

enable_aio;
IO::AIO::max_outstanding 128;

sub find_rcfile($) {
   my $path;

   for (@INC) {
      $path = "$_/Gtk2/CV/$_[0]";
      return $path if -r $path;
   }

   die "FATAL: can't find required file $_[0]\n";
}

sub require_image($) {
   new_from_file Gtk2::Gdk::Pixbuf find_rcfile "images/$_[0]";
}

sub dealpha_compose($) {
   return $_[0] unless $_[0]->get_has_alpha;

   Gtk2::CV::dealpha_expose $_[0]->composite_color_simple (
      $_[0]->get_width, $_[0]->get_height,
      'nearest', 255, 16, 0xffc0c0c0, 0xff606060,
   )
}

# TODO: make preferences
sub dealpha($) {
   &dealpha_compose
}

1;


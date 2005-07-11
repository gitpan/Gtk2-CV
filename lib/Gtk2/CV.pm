package Gtk2::CV;

use XSLoader;

$VERSION = '0.5';

XSLoader::load "Gtk2::CV", $VERSION;

use Gtk2;
use Glib;

use IO::AIO;

add_watch Glib::IO IO::AIO::poll_fileno,
                   in => sub { IO::AIO::poll_cb, 1 };
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

1;


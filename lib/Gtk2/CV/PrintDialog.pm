package Gtk2::CV::PrintDialog;

use Gtk2;
use Gtk2::Gdk::Keysyms;

use Gtk2::CV;
use Gtk2::CV::PostScript;

use Gtk2::GladeXML;

sub new {
   my $class = shift;
   my $self = bless { @_ }, $class;

   $self->{dialog} = my $d = new Gtk2::GladeXML Gtk2::CV::find_rcfile "cv.glade", "PrintDialog";
   #$d->signal_connect_all ...

   $d->get_widget ("destination")->set (text => $ENV{CV_PRINT_DESTINATION} || "| lpr");

   my $menu = $d->get_widget ("papersize")->get_menu;
   for (Gtk2::CV::PostScript->papersizes) {
      my ($code, $name, $w, $h) = @$_;
      $menu->append (my $item = new Gtk2::MenuItem $name);
      $item->set_name ($code);
   }
   $menu->show_all;

   $d->get_widget ("papersize")->set_history (0);

   $d->get_widget ("PrintDialog")->signal_connect (close => sub {
      $_[0]->destroy;
   });

   $d->get_widget ("PrintDialog")->signal_connect (response => sub {
      if ($_[1] eq "ok") {
         $self->print (
            size        => (Gtk2::CV::PostScript->papersizes)[$d->get_widget ("papersize")->get_history],
            margin      => $d->get_widget ("margin")->get_value,
            color       => $d->get_widget ("type_color")->get ("active"),
            interpolate => $d->get_widget ("interpolate_enable")->get ("active")
                              ? $d->get_widget ("interpolate_mb")->get_value
                              : 0,
            dest_type   => (qw(perl file pipe))[$d->get_widget ("dest_type")->get_history],
            destination => $d->get_widget ("destination")->get ("text"),
         );
      }
      $_[0]->destroy;
   });

   $self;
}

sub on_dest_activate {
   my $self = shift->get_widget_tree;
   #warn $_[0]->get_name;
   #$_[0]->get_widget_tree->get_widget ("destination")->set (
}

sub print {
   my ($self, %arg) = @_;

   my $fh;

   if ($arg{dest_type} eq "file") {
      open $fh, ">", $arg{destination};
   } elsif ($arg{dest_type} eq "pipe") {
      open $fh, "-|", $arg{destination};
   } else {
      open $fh, $arg{destination};
   }

   $fh or die "$arg{destination}: $!";

   (new Gtk2::CV::PostScript fh => $fh, %arg, %$self)->print;

   close $fh or die "$arg{destination}: $!";
}

1;

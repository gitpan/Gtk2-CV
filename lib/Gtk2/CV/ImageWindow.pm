package Gtk2::CV::ImageWindow;

use Gtk2;
use Gtk2::Gdk::Keysyms;

use Gtk2::CV;

use List::Util qw(min max);

my $title_img = Gtk2::CV::require_image "cv.png";

use Glib::Object::Subclass
   Gtk2::Window,
   properties => [
      Glib::ParamSpec->string ("path", "Pathname", "The image pathname", "", [qw(writable readable)]),
   ],
   signals => {
      image_changed => { flags => [qw/run-first/], return_type => undef, param_types => [] },
   };

sub INIT_INSTANCE {
   my ($self) = @_;

   $self->push_composite_child;

   $self->double_buffered (0);

   $self->signal_connect (realize => sub { $self->do_realize });
   $self->signal_connect (expose_event => sub { 1 });
   $self->signal_connect (configure_event => sub { $self->do_configure ($_[1]) });
   $self->signal_connect (delete_event => sub { main_quit Gtk2 });
   $self->signal_connect (key_press_event => sub { $self->handle_key ($_[1]->keyval) });
   $self->signal_connect (button_press_event => sub { $self->do_button_press (1, $_[1]) });
   $self->signal_connect (button_release_event => sub { $self->do_button_press (0, $_[1]) });

   $self->add_events ([qw(key_press_mask focus-change-mask button_press_mask button_release_mask)]);
   $self->can_focus (1);
   $self->set_size_request (0, 0);

   $self->{interp} = 'bilinear';

   $self->pop_composite_child;

   $self->clear_image;
}

sub SET_PROPERTY { 
   my ($self, $pspec, $newval) = @_;

   $pspec = $pspec->get_name;
   
   if ($pspec eq "path") {
      $self->load_image ($newval);
   } else {
      $self->{$pspec} = $newval;
   }
}

sub do_image_changed {
   my ($self) = @_;
}

sub set_image {
   my ($self, $image) = @_;

   $self->{image} = $image;

   $self->{iw} = $image->get_width;
   $self->{ih} = $image->get_height;
   $self->{ix} = $self->{iy} = 0;

   if ($self->{iw} > $self->{sw} || $self->{ih} > $self->{sh}) {
      $self->resize_maxpect;
   } elsif ($self->{iw} > 0 && $self->{ih} > 0) {
      $self->resize ($self->{iw}, $self->{ih});
   } else {
      $self->clear_image;
   }
}

sub clear_image {
   my ($self) = @_;

   $self->set_image ($title_img);
}

sub load_image {
   my ($self, $path) = @_;

   $self->{path} = $path;

   delete $self->{dw};

   my $image = eval { new_from_file Gtk2::Gdk::Pixbuf $path };

   if ($image) {
      $self->set_image ($image);
      $self->set_title ("CV: $path");
   } else {
      $self->clear_image;
   }
}

sub do_realize {
   my ($self, $mapped) = @_;

   $self->{window} = $self->window;
   $self->{sw} = $self->{window}->get_screen->get_width;
   $self->{sh} = $self->{window}->get_screen->get_height;

   $self->resize ($self->{iw}, $self->{ih}) if $self->{image};

   0;
}

sub do_button_press {
   my ($self, $press, $event) = @_;

   my $x = $event->x / $self->{sx} + $self->{ix};
   my $y = $event->y / $self->{sy} + $self->{iy};

   if ($press) {
      $self->{ix_} = $x;
      $self->{iy_} = $y;
   } else {
      ($x, $self->{ix_}) = ($self->{ix_}, $x) if $self->{ix_} > $x;
      ($y, $self->{iy_}) = ($self->{iy_}, $y) if $self->{iy_} > $y;

      $self->crop (delete $self->{ix_}, delete $self->{iy_}, $x, $y);
   }
}

sub resize_maxpect {
   my ($self) = @_;

   my ($w, $h) = ($self->{iw} * $self->{sh} / $self->{ih}, $self->{sh});
   ($w, $h) = ($self->{sw}, $self->{ih} * $self->{sw} / $self->{iw}) if $w > $self->{sw};
   $self->resize ($w, $h);
}

sub resize {
   my ($self, $w, $h) = @_;
   
   if (my $window = $self->{window}) {
      my $w = max (16, min ($self->{sw}, $w));
      my $h = max (16, min ($self->{sh}, $h));

      delete $self->{dw}; # hack to force redraw because we nuke the bg pixmap
      $self->{window}->set_back_pixmap (undef, 0);

      my ($x, $y) = $window->get_position;
      my $nx = max 0, min $self->{sw} - $w, $x;
      my $ny = max 0, min $self->{sh} - $h, $y;
      $window->move ($nx, $ny) if $nx != $x || $ny != $y;
      $window->resize ($w, $h);
   }
}

sub uncrop {
   my ($self) = @_;

   $self->{ix} = $self->{iy} = 0;
   $self->{iw} = $self->{image}->get_width;
   $self->{ih} = $self->{image}->get_height;

   $self->resize ($self->{iw}, $self->{ih});
}

sub crop {
   my ($self, $x1, $y1, $x2, $y2) = @_;

   $self->{ix} = $x1;
   $self->{iy} = $y1;
   $self->{iw} = $x2 - $x1;
   $self->{ih} = $y2 - $y1;

   if ($self->{iw} && $self->{ih}) {
      $self->resize ($self->{iw}, $self->{ih});
   } else {
      $self->uncrop;
   }
}

sub handle_key {
   my ($self, $key) = @_;

   if ($key == $Gtk2::Gdk::Keysyms{less}) {
      $self->resize ($self->{dw} * 0.5, $self->{dh} * 0.5);

   } elsif ($key == $Gtk2::Gdk::Keysyms{greater}) {
      $self->resize ($self->{dw} * 2, $self->{dh} * 2);

   } elsif ($key == $Gtk2::Gdk::Keysyms{comma}) {
      $self->resize ($self->{dw} * 0.9, $self->{dh} * 0.9);

   } elsif ($key == $Gtk2::Gdk::Keysyms{period}) {
      $self->resize ($self->{dw} * 1.1, $self->{dh} * 1.1);

   } elsif ($key == $Gtk2::Gdk::Keysyms{n}) {
      $self->resize ($self->{iw}, $self->{ih});

   } elsif ($key == $Gtk2::Gdk::Keysyms{m}) {
      $self->resize ($self->{sw}, $self->{sh});

   } elsif ($key == $Gtk2::Gdk::Keysyms{M}) {
      $self->resize_maxpect;

   } elsif ($key == $Gtk2::Gdk::Keysyms{u}) {
      $self->uncrop;

   } elsif ($key == $Gtk2::Gdk::Keysyms{r}) {
      $self->{interp} = 'nearest';
      $self->redraw;

   } elsif ($key == $Gtk2::Gdk::Keysyms{s}) {
      $self->{interp} = 'bilinear';
      $self->redraw;

   } elsif ($key == $Gtk2::Gdk::Keysyms{S}) {
      $self->{interp} = 'hyper';
      $self->redraw;

   } elsif ($key == $Gtk2::Gdk::Keysyms{t}) {
      $self->set_image (flop (transpose $self->{image}));

   } elsif ($key == $Gtk2::Gdk::Keysyms{T}) {
      $self->set_image (transpose (flop $self->{image}));

   } else {

      return 0;
   }

   1;
}

sub redraw {
   my ($self) = @_;

   return unless $self->{window} && $self->{image};

   $self->{window}->set_back_pixmap (undef, 0);

   my $pb = $self->{image};
   my $pm = new Gtk2::Gdk::Pixmap $self->{window}, $self->{dw}, $self->{dh}, -1;

   if ($self->{iw} != $self->{dw} or $self->{ih} != $self->{dh}
       or $self->{ix} or $self->{iy}) {
      $self->{sx} = $self->{dw} / $self->{iw};
      $self->{sy} = $self->{dh} / $self->{ih};
      $pb = new Gtk2::Gdk::Pixbuf 'rgb', $pb->get_has_alpha, 8, $self->{dw}, $self->{dh};
      $self->{image}->scale ($pb, 0, 0, $self->{dw}, $self->{dh},
                  -$self->{ix} * $self->{sx}, -$self->{iy} * $self->{sy},
                  $self->{sx}, $self->{sy},
                  $self->{interp});
   } else {
      $self->{sx} =
      $self->{sy} = 1;
   }

   $pm->draw_pixbuf ($self->style->white_gc,
         $pb,
         0, 0, 0, 0, $self->{dw}, $self->{dh},
         "normal", 0, 0);

   $self->{window}->set_back_pixmap ($pm);

   $self->window->clear_area (0, 0, $self->{w}, $self->{h});
}

sub do_configure {
   my ($self, $event) = @_;

   my $window = $self->window;

   my $sw = $self->{sw} = $window->get_screen->get_width;
   my $sh = $self->{sh} = $window->get_screen->get_height;

   my ($x, $y) = ($event->x, $event->y);
   my ($w, $h) = ($event->width, $event->height);

   $self->{w} = $w;
   $self->{h} = $h;

   return if $self->{dw} == $w && $self->{dh} == $h;

   $self->{window}->set_back_pixmap (undef, 0);

   remove Glib::Source $self->{refresh} if exists $self->{refresh};

   return unless $self->{image};

   $w = max (16, $w);
   $h = max (16, $h);

   $self->{dw} = $w;
   $self->{dh} = $h;

   $self->{refresh} = add Glib::Idle sub {
      delete $self->{refresh};

      $self->redraw;
      0
   };
}

1;

package Gtk2::CV::ImageWindow;

use Gtk2;
use Gtk2::Gdk::Keysyms;

use Gtk2::CV;
use Gtk2::CV::PrintDialog;

use List::Util qw(min max);

my $title_img = Gtk2::CV::require_image "cv.png";

# no, muppet, it's not for speed, it's for readability only :)
my $gtk20 = (Gtk2->get_version_info)[1] < 2;

use Glib::Object::Subclass
   Gtk2::Window,
   properties => [
      Glib::ParamSpec->string ("path", "Pathname", "The image pathname", "", [qw(writable readable)]),
   ],
   signals => {
      image_changed        => { flags => [qw/run-first/], return_type => undef, param_types => [] },
      button3_press_event  => { flags => [qw/run-first/], return_type => undef, param_types => [] },

      button_press_event   => sub { $_[0]->do_button_press (1, $_[1]) },
      button_release_event => sub { $_[0]->do_button_press (0, $_[1]) },
      motion_notify_event  => \&motion_notify_event,
   };

sub INIT_INSTANCE {
   my ($self) = @_;

   $self->push_composite_child;

   $self->double_buffered (0);

   $self->signal_connect (realize => sub { $self->do_realize });
   $self->signal_connect (map_event => sub { $self->auto_position (($self->allocation->values)[2,3]) });
   $self->signal_connect (expose_event => sub { 1 });
   $self->signal_connect (configure_event => sub { $self->do_configure ($_[1]) });
   $self->signal_connect (delete_event => sub { main_quit Gtk2 });
   $self->signal_connect (key_press_event => sub { $self->handle_key ($_[1]->keyval, $_[1]->state) });

   $self->add_events ([qw(key_press_mask focus-change-mask button_press_mask
                          button_release_mask pointer-motion-hint-mask pointer-motion-mask)]);
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

sub set_subimage {
   my ($self, $image) = @_;

   delete $self->{dw};

   $self->{subimage} = $image;

   $self->{iw} = $image->get_width;
   $self->{ih} = $image->get_height;

   if ($self->{iw} && $self->{ih}) {
      $self->auto_resize;
   } else {
      $self->clear_image;
   }
}


sub set_image {
   my ($self, $image) = @_;

   $self->{image} = $image;

   $self->set_subimage ($image);
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

   if ($gtk20) {
      $self->{sw} = Gtk2::Gdk->screen_width;
      $self->{sh} = Gtk2::Gdk->screen_height;
   } else {
      $self->{sw} = $self->{window}->get_screen->get_width;
      $self->{sh} = $self->{window}->get_screen->get_height;
   }

   $self->auto_resize if $self->{image};

   $self->{drag_gc} = Gtk2::Gdk::GC->new ($self->window);
   $self->{drag_gc}->set_function ('xor');
   $self->{drag_gc}->set_foreground ($self->style->white);

   0;
}

sub draw_drag_rect {
   my $self = shift;

   my $d = $self->{drag_info};

   my $x = min @$d[0,2];
   my $y = min @$d[1,3];

   my $w = abs $d->[2] - $d->[0] - 1;
   my $h = abs $d->[3] - $d->[1] - 1;

   $self->window->draw_rectangle ($self->{drag_gc}, 0, $x, $y, $w, $h);
}

sub do_button_press {
   my ($self, $press, $event) = @_;

   if ($event->button == 3) {
      $self->signal_emit ("button3_press_event") if $press;
   } else {
      if ($press) {
         $self->{drag_info} = [ ($event->x, $event->y) x 2 ];
         $self->draw_drag_rect;
      } else {
         my $d = delete $self->{drag_info};

         return 0 unless $d;

         $self->crop (
            (min @$d[0,2]) / $self->{sx},
            (min @$d[1,3]) / $self->{sy},
            (max @$d[0,2]) / $self->{sx},
            (max @$d[1,3]) / $self->{sy},
         );
      }
   }

   1;
}

sub motion_notify_event {
   my ($self, $event) = @_;

   return unless $self->{drag_info};

   my ($x, $y, $state);

   if ($event->is_hint) {
      (undef, $x, $y, $state) = $event->window->get_pointer;
   } else {
      $x = $event->x;
      $y = $event->y;
      $state = $event->state;
   }
   $x = max 0, min $self->{dw}, $event->x;
   $y = max 0, min $self->{dh}, $event->y;

   # erase last
   $self->draw_drag_rect;

   # draw next
   @{$self->{drag_info}}[2,3] = ($x, $y);
   $self->draw_drag_rect;

   1;
}

sub auto_position {
   my ($self, $w, $h) = @_;

   if (my $window = $self->{window}) {
      my ($x, $y) = $window->get_position;
      my $nx = max 0, min $self->{sw} - $w, $x;
      my $ny = max 0, min $self->{sh} - $h, $y;
      $window->move ($nx, $ny) if $nx != $x || $ny != $y;
   }
}

sub auto_resize {
   my ($self) = @_;

   return unless $self->{window};

   if ($self->{maxpect}
       || $self->{iw} > $self->{sw}
       || $self->{ih} > $self->{sh}) {
      $self->resize_maxpect;
   } else {
      $self->resize ($self->{iw}, $self->{ih});
   }

   #$self->{window}->process_all_updates;
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

      $window->set_back_pixmap (undef, 0);

      $self->auto_position ($w, $h);
      $window->resize ($w, $h);
   }
}

sub uncrop {
   my ($self) = @_;

   $self->set_subimage ($self->{image});
}

sub crop {
   my ($self, $x1, $y1, $x2, $y2) = @_;

   $x2 -= $x1;
   $y2 -= $y1;

   if ($x2 && $y2) {
      $self->set_subimage (
         $self->{subimage}->new_subpixbuf ($x1, $y1, $x2, $y2)
      );
   } else {
      $self->uncrop;
   }
}

sub handle_key {
   my ($self, $key, $state) = @_;

   if ($state * "control-mask") {
      if ($key == $Gtk2::Gdk::Keysyms{p}) {
         new Gtk2::CV::PrintDialog pixbuf => $self->{subimage}, aspect => $self->{dw} / $self->{dh};

      } elsif ($key == $Gtk2::Gdk::Keysyms{m}) {
         $self->{maxpect} = !$self->{maxpect};
         $self->auto_resize;

      } else {
         return 0;
      }

   } else {
      if ($key == $Gtk2::Gdk::Keysyms{less}) {
         $self->resize ($self->{dw} * 0.5, $self->{dh} * 0.5);

      } elsif ($key == $Gtk2::Gdk::Keysyms{greater}) {
         $self->resize ($self->{dw} * 2, $self->{dh} * 2);

      } elsif ($key == $Gtk2::Gdk::Keysyms{comma}) {
         $self->resize ($self->{dw} * 0.9, $self->{dh} * 0.9);

      } elsif ($key == $Gtk2::Gdk::Keysyms{period}) {
         $self->resize ($self->{dw} * 1.1, $self->{dh} * 1.1);

      } elsif ($key == $Gtk2::Gdk::Keysyms{n}) {
         $self->auto_resize;

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
         $self->set_subimage (flop (transpose $self->{subimage}));

      } elsif ($key == $Gtk2::Gdk::Keysyms{T}) {
         $self->set_subimage (transpose (flop $self->{subimage}));

      } elsif ($key == $Gtk2::Gdk::Keysyms{Escape}
               && $self->{drag_info}) {
         # cancel a crop
         $self->draw_drag_rect;

         delete $self->{drag_info};

      } else {

         return 0;
      }
   }

   1;
}

sub redraw {
   my ($self) = @_;

   return unless $self->{window} && $self->{image};

   $self->{window}->set_back_pixmap (undef, 0);

   my $pb = $self->{subimage};
   my $pm = new Gtk2::Gdk::Pixmap $self->{window}, $self->{dw}, $self->{dh}, -1;

   if ($self->{iw} != $self->{dw} or $self->{ih} != $self->{dh}) {
      $self->{sx} = $self->{dw} / $self->{iw};
      $self->{sy} = $self->{dh} / $self->{ih};
      $pb = new Gtk2::Gdk::Pixbuf 'rgb', $pb->get_has_alpha, 8, $self->{dw}, $self->{dh};
      $self->{subimage}->scale ($pb, 0, 0, $self->{dw}, $self->{dh},
                  0, 0,
                  $self->{sx}, $self->{sy},
                  $self->{interp});
   } else {
      $self->{sx} =
      $self->{sy} = 1;
   }

   if ($gtk20) {
      $pb->render_to_drawable ($pm,
             $self->style->white_gc,
             0, 0, 0, 0, $self->{dw}, $self->{dh},
            'normal', 0, 0);
   } else {
      $pm->draw_pixbuf ($self->style->white_gc,
            $pb,
            0, 0, 0, 0, $self->{dw}, $self->{dh},
            "normal", 0, 0);
   }

   $self->{window}->set_back_pixmap ($pm);

   $self->window->clear_area (0, 0, $self->{w}, $self->{h});
}

sub do_configure {
   my ($self, $event) = @_;

   my $window = $self->window;

   my ($sw, $sh) = ($self->{sw}, $self->{sh});

   my ($x, $y) = ($event->x, $event->y);
   my ($w, $h) = ($event->width, $event->height);

   $self->{w} = $w;
   $self->{h} = $h;

   return if $self->{dw} == $w && $self->{dh} == $h;

   $self->{window}->set_back_pixmap (undef, 0);

   remove Glib::Source $self->{refresh} if exists $self->{refresh};

   return unless $self->{subimage};

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

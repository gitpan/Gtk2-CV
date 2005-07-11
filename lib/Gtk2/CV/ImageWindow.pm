package Gtk2::CV::ImageWindow;

use Gtk2;
use Gtk2::Gdk::Keysyms;

use Gtk2::CV;
use Gtk2::CV::PrintDialog;

use List::Util qw(min max);

use POSIX ();
use FileHandle ();

my $title_img = Gtk2::CV::require_image "cv.png";

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
   #$self->set_resize_mode ("immediate");

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

sub FINALIZE_INSTANCE {
   my ($self) = @_;

   $self->kill_mplayer;
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

sub kill_mplayer {
   my ($self) = @_;

   if ($self->{mplayer_pid} > 0) {
      local $SIG{PIPE} = 'IGNORE';
      print {$self->{mplayer_fh}} "quit\n";
      close $self->{mplayer_fh};
      #kill INT => $self->{mplayer_pid};
      waitpid delete $self->{mplayer_pid}, 0;
      (delete $self->{mplayer_box})->destroy;
   }
}

sub clear_image {
   my ($self) = @_;

   $self->kill_mplayer;
   $self->set_image ($title_img);
}

sub load_image {
   my ($self, $path) = @_;

   $self->kill_mplayer;
   delete $self->{dw};

   $self->{path} = $path;

   my $image = eval { new_from_file Gtk2::Gdk::Pixbuf $path };

   if (!$image) {
      $path = "./$path" if $path =~ /^-/;

      # try video
      my $mplayer = qx{LC_ALL=C exec mplayer </dev/null 2>/dev/null -sub /dev/null -sub-fuzziness 0 -nolirc -cache-min 0 -noconsolecontrols -identify -vo null -ao null -frames 0 \Q$path};

      my $w = $mplayer =~ /^ID_VIDEO_WIDTH=(\d+)$/sm ? $1 : undef;
      my $h = $mplayer =~ /^ID_VIDEO_HEIGHT=(\d+)$/sm ? $1 : undef;

      if ($w && $h) {
         if ($mplayer =~ /^ID_VIDEO_ASPECT=([0-9\.]+)$/sm && $1 > 0) {
            $w = POSIX::ceil $w * $1 * ($h / $w); # correct aspect ratio, assume square pixels
         } else {
            # no idea what to do, mplayer's aspect fatcors seem to be random
            #$w = POSIX::ceil $w * 1.50 * ($h / $w); # correct aspect ratio, assume square pixels
            #$w = POSIX::ceil $w * 1.33;
         }

         $image = new Gtk2::Gdk::Pixbuf "rgb", 0, 8, $w, $h;
         $image->fill ("\0\0\0");

         # d'oh, we need to do that because realize() doesn't reliably cause
         # the window to have the correct size
         $self->show;

         # add a couple of windows just for mplayer's sake
         my $box = $self->{mplayer_box} = new Gtk2::EventBox;
         $box->set_above_child (1);
         $box->set_visible_window (0);
         $box->set_events ([]);
         my $window = $self->{mplayer_window} = new Gtk2::DrawingArea;
         $box->add ($window);
         $self->add ($box);
         $box->show_all;

         $self->{mplayer_window}->realize;
         my $xid = $self->{mplayer_window}->window->get_xid;

         pipe my $rfh, $self->{mplayer_fh};
         $self->{mplayer_fh}->autoflush (1);

         $self->{mplayer_pid} = fork;

         if ($self->{mplayer_pid} == 0) {
            open STDIN, "<&" . fileno $rfh;
            open STDOUT, ">/dev/null";
            open STDERR, ">/dev/null";
            exec "mplayer", qw(-slave -nofs -nokeepaspect -noconsolecontrols -nomouseinput -zoom -fixed-vo -loop 0),
                            -screenw => $w, -screenh => $h, -wid => $xid, $path;
            POSIX::_exit 0;
         }

         close $rfh;
      } else {
         # probably audio, or a real error
      }
   } elsif ($@) {
      warn "$@";
   }

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

   if ($self->{window}) {
      my ($x, $y) = $self->get_position;
      my $nx = max 0, min $self->{sw} - $w, $x;
      my $ny = max 0, min $self->{sh} - $h, $y;
      $self->move ($nx, $ny) if $nx != $x || $ny != $y;
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
}

sub resize_maxpect {
   my ($self) = @_;

   my ($w, $h) = (int ($self->{iw} * $self->{sh} / $self->{ih}),
                  int ($self->{sh}));
   ($w, $h) = ($self->{sw}, $self->{ih} * $self->{sw} / $self->{iw}) if $w > $self->{sw};
   $self->resize ($w, $h);
}

sub resize {
   my ($self, $w, $h) = @_;
   
   return unless $self->{window};

   my $w = max (16, min ($self->{sw}, $w));
   my $h = max (16, min ($self->{sh}, $h));

   $self->{dw} = $w;
   $self->{dh} = $h;

   $self->auto_position ($w, $h);
   $self->window->resize ($w, $h);

   $self->redraw;
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

   local $SIG{PIPE} = 'IGNORE'; # for mplayer_fh

   if ($state * "control-mask") {
      if ($key == $Gtk2::Gdk::Keysyms{p}) {
         new Gtk2::CV::PrintDialog pixbuf => $self->{subimage}, aspect => $self->{dw} / $self->{dh};

      } elsif ($key == $Gtk2::Gdk::Keysyms{m}) {
         $self->{maxpect} = !$self->{maxpect};
         $self->auto_resize;

      } elsif ($key == $Gtk2::Gdk::Keysyms{e}) {
         if (fork == 0) {
            exec $ENV{CV_EDITOR} || "gimp", $self->{path};
            exit;
         }

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
         $self->set_subimage (Gtk2::CV::flop (Gtk2::CV::transpose $self->{subimage}));

      } elsif ($key == $Gtk2::Gdk::Keysyms{T}) {
         $self->set_subimage (Gtk2::CV::transpose (Gtk2::CV::flop $self->{subimage}));

      } elsif ($key == $Gtk2::Gdk::Keysyms{Escape}
               && $self->{drag_info}) {
         # cancel a crop
         $self->draw_drag_rect;

         delete $self->{drag_info};

      # extra mplayer controls
      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{Right}) {
         print {$self->{mplayer_fh}} "seek +10\n";
      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{Left}) {
         print {$self->{mplayer_fh}} "seek -10\n";
      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{Up}) {
         print {$self->{mplayer_fh}} "seek +60\n";
      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{Down}) {
         print {$self->{mplayer_fh}} "seek -60\n";
      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{Page_Up}) {
         print {$self->{mplayer_fh}} "seek +600\n";
      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{Page_Down}) {
         print {$self->{mplayer_fh}} "seek -600\n";
      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{o}) {
         print {$self->{mplayer_fh}} "osd\n";
      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{p}) {
         print {$self->{mplayer_fh}} "pause\n";
      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{Escape}) {
         print {$self->{mplayer_fh}} "quit\n";
      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{9}) {
         print {$self->{mplayer_fh}} "volume -1\n";
      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{0}) {
         print {$self->{mplayer_fh}} "volume 1\n";
#      } elsif ($self->{mplayer_pid} && $key == $Gtk2::Gdk::Keysyms{f}) {
#         print {$self->{mplayer_fh}} "vo_fullscreen\n";

      } else {

         return 0;
      }
   }

   1;
}

sub schedule_redraw {
   my ($self) = @_;

   $self->{refresh} ||= add Glib::Idle sub {
      delete $self->{refresh};

      $self->redraw;
      0
   }, undef, 10;
}

sub redraw {
   my ($self) = @_;

   return unless $self->{window};

   $self->{window}->set_back_pixmap (undef, 0);

   my $pb = $self->{subimage}
      or return;

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

   $pm->draw_pixbuf ($self->style->white_gc,
                     $pb,
                     0, 0, 0, 0, $self->{dw}, $self->{dh},
                     "normal", 0, 0);

   $self->{window}->set_back_pixmap ($pm);

   $self->window->clear_area (0, 0, $self->{dw}, $self->{dh});

   Gtk2::Gdk->flush;
}

sub do_configure {
   my ($self, $event) = @_;

   my $window = $self->window;

   my ($sw, $sh) = ($self->{sw}, $self->{sh});

   my ($x, $y) = ($event->x, $event->y);
   my ($w, $h) = ($event->width, $event->height);

   $self->{w} = $w;
   $self->{h} = $h;

   return unless $self->{subimage};

   $w = max (16, $w);
   $h = max (16, $h);

   return if $self->{dw} == $w && $self->{dh} == $h;

   $self->{dw} = $w;
   $self->{dh} = $h;

   $self->schedule_redraw;
}

1;

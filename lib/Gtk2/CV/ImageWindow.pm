=head1 NAME

Gtk2::CV::ImageWindow - a window widget displaying an image or other media

=head1 SYNOPSIS

  use Gtk2::CV::ImageWindow;

=head1 DESCRIPTION

=head2 METHODS

=over 4

=cut

package Gtk2::CV::ImageWindow;

use Gtk2;
use Gtk2::Gdk::Keysyms;

use Gtk2::CV;
use Gtk2::CV::PrintDialog;

use List::Util qw(min max);

use Scalar::Util;
use POSIX ();
use FileHandle ();

my $title_image;

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
      show                 => sub {
         $_[0]->realize_image;
         $_[0]->signal_chain_from_overridden;
      },
   };

sub INIT_INSTANCE {
   my ($self) = @_;

   $self->push_composite_child;

   $self->double_buffered (0);

   $self->signal_connect (realize => sub { $_[0]->do_realize; 0 });
   $self->signal_connect (map_event => sub { $_[0]->check_screen_size; $_[0]->auto_position (($_[0]->allocation->values)[2,3]) });
   $self->signal_connect (expose_event => sub {
      # in most cases, we get no expose events, except when our _own_ popups
      # obscure some part of the window. se we have to do lots of unneessary refreshes :(
      $self->{window}->clear_area ($_[1]->area->values);
      $self->draw_drag_rect ($_[1]->area);
      1 
   });
   $self->signal_connect (configure_event => sub { $_[0]->do_configure ($_[1]); 0 });
   $self->signal_connect (key_press_event => sub { $_[0]->handle_key ($_[1]->keyval, $_[1]->state) });

   $self->{frame_extents_property}         = Gtk2::Gdk::Atom->intern ("_NET_FRAME_EXTENTS", 0);
   $self->{request_frame_extents_property} = Gtk2::Gdk::Atom->intern ("_NET_REQUEST_FRAME_EXTENTS", 0);

   $self->signal_connect (property_notify_event => sub {
      return unless $_[0]{frame_extents_property} == $_[1]->atom;

      $self->update_properties;

      0
   });

   $self->add_events ([qw(key_press_mask focus-change-mask button_press_mask property_change_mask
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

sub set_subimage {
   my ($self, $image) = @_;

   $self->force_redraw;

   $self->{subimage} = $image;

   $self->{iw} = $image->get_width;
   $self->{ih} = $image->get_height;

   if ($self->{iw} && $self->{ih}) {
      $self->auto_resize;
   } else {
      $self->clear_image;
   }
}

=item $img->set_image ($gdk_pixbuf)

Replace the currently-viewed image by the givne pixbuf.

=cut

sub set_image {
   my ($self, $image) = @_;

   $self->{image} = $image;

   $self->set_subimage ($image);
}

=item $img->clear_image

Removes the current image (usually replacing it by the default image).

=cut

sub clear_image {
   my ($self) = @_;

   $self->kill_mplayer;

   delete $self->{image};
   delete $self->{subimage};

   if ($self->{window} && $self->{window}->is_visible) {
      $self->realize_image;
   }
}

sub realize_image {
   my ($self) = @_;

   return if $self->{image};

   $title_image ||= Gtk2::CV::require_image "cv.png";
   $self->set_image ($title_image);
   Scalar::Util::weaken $title_image;
}

=item $img->load_image ($path)

Tries to load the given file (if it is an image), or embeds mplayer (if
mplayer supports it).

=cut

sub load_image {
   my ($self, $path) = @_;

   $self->kill_mplayer;
   $self->force_redraw;

   $self->{path} = $path;

   my $image = eval { $path =~ /\.jpe?g$/i && Gtk2::CV::load_jpeg $path }
               || eval { new_from_file Gtk2::Gdk::Pixbuf $path };

   if (!$image) {
      local $@;

      $path = "./$path" if $path =~ /^-/;

      # try video
      my $mplayer = qx{LC_ALL=C exec mplayer </dev/null 2>/dev/null -sub /dev/null -sub-fuzziness 0 -nolirc -cache-min 0 -noconsolecontrols -identify -vo null -ao null -frames 0 \Q$path};

      my $w = $mplayer =~ /^ID_VIDEO_WIDTH=(\d+)$/sm ? $1 : undef;
      my $h = $mplayer =~ /^ID_VIDEO_HEIGHT=(\d+)$/sm ? $1 : undef;

      if ($w && $h) {
         if ($mplayer =~ /^ID_VIDEO_ASPECT=([0-9\.]+)$/sm && $1 > 0) {
            $w = POSIX::ceil $w * $1 * ($h / $w); # correct aspect ratio, assume square pixels
         } else {
            # no idea what to do, mplayer's aspect factors seem to be random
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

         my $window = new Gtk2::DrawingArea;
         $box->add ($window);
         # some extra flickering to force configure events to mplayer
         $window->signal_connect (event => sub {
            $self->update_mplayer_window
               if $_[1]->type =~ /^(?:map|property-notify)$/;

            0
         });
         $self->add ($box);
         $box->show_all;
         $window->realize;
         $self->{mplayer_window} = $window;

         my $xid = $window->window->get_xid;

         pipe my $rfh, $self->{mplayer_fh};
         $self->{mplayer_fh}->autoflush (1);

         $self->{mplayer_pid} = fork;

         if ($self->{mplayer_pid} == 0) {
            open STDIN, "<&" . fileno $rfh;
            open STDOUT, ">/dev/null";
            open STDERR, ">/dev/null";
            exec "mplayer", qw(-slave -nofs -nokeepaspect -noconsolecontrols -nomouseinput -zoom -fixed-vo -loop 0),
                            -wid => $xid, $path;
            POSIX::_exit 0;
         }

         close $rfh;
      } else {
         # probably audio, or a real error
      }
   }

   if (!$image) {
      warn "$@";

      $image = Gtk2::CV::require_image "error.png";
   }

   if ($image) {
      $self->set_image ($image);
      $self->set_title ("CV: $path");
   } else {
      $self->clear_image;
   }
}

sub check_screen_size {
   my ($self) = @_;

   my ($left, $right, $top, $bottom) = @{ $self->{frame_extents} || [] };

   my $sw = $self->{screen_width}  - ($left + $right);
   my $sh = $self->{screen_height} - ($top + $bottom);

   if ($self->{sw} != $sw || $self->{sh} != $sh) {
      ($self->{sw},  $self->{sh})  = ($sw, $sh);
      ($self->{rsw}, $self->{rsh}) = ($sw, $sh);
      $self->auto_resize if $self->{image};
   }
}

sub update_properties {
   my ($self) = @_;

   (undef, undef, @data) = $_[0]->{window}->property_get (
      $_[0]{frame_extents_property}, 
      Gtk2::Gdk::Atom->intern ("CARDINAL", 0),
      0, 4*4, 0);
   # left, right, top, bottom
   $self->{frame_extents} = \@data;

   $self->check_screen_size;
}

sub request_frame_extents {
   my ($self) = @_;

   return if $self->{frame_extents};
   return unless Gtk2::CV::gdk_net_wm_supports $self->{request_frame_extents_property};

   # TODO
   # send clientmessage
}

sub do_realize {
   my ($self) = @_;

   $self->{window} = $self->window;

   $self->{drag_gc} = Gtk2::Gdk::GC->new ($self->{window});
   $self->{drag_gc}->set_function ('xor');
   $self->{drag_gc}->set_rgb_foreground (new Gtk2::Gdk::Color 128*257, 128*257, 128*257);
   $self->{drag_gc}->set_line_attributes (1, 'solid', 'round', 'miter');

   $self->{screen_width}  = $self->{window}->get_screen->get_width;
   $self->{screen_height} = $self->{window}->get_screen->get_height;

   $self->realize_image;
   $self->request_frame_extents;

   $self->check_screen_size;

   0
}

sub draw_drag_rect {
   my ($self, $area) = @_;

   my $d = $self->{drag_info}
      or return;

   my $x1 = min @$d[0,2];
   my $y1 = min @$d[1,3];

   my $x2 = max @$d[0,2];
   my $y2 = max @$d[1,3];

   $_ = $self->{sx} * int .5 + $_ / $self->{sx} for ($x1, $x2);
   $_ = $self->{sy} * int .5 + $_ / $self->{sy} for ($y1, $y2);

   $self->{drag_gc}->set_clip_rectangle ($area)
      if $area;

   $self->{window}->draw_rectangle ($self->{drag_gc}, 0,
                                    $x1, $y1, $x2 - $x1, $y2 - $y1);

   # workaround for Gtk2-bug, arg should be undef
   $self->{drag_gc}->set_clip_region ($self->{window}->get_clip_region)
      if $area;
}

sub do_button_press {
   my ($self, $press, $event) = @_;

   if ($event->button == 3) {
      $self->signal_emit ("button3_press_event") if $press;
   } else {
      if ($press) {
         $self->{drag_info} = [ ($event->x, $event->y) x 2 ];
         $self->draw_drag_rect;
      } elsif ($self->{drag_info}) {
         $self->draw_drag_rect;

         my $d = delete $self->{drag_info};

         my ($x1, $y1, $x2, $y2) = (
            (min @$d[0,2]) / $self->{sx},
            (min @$d[1,3]) / $self->{sy},
            (max @$d[0,2]) / $self->{sx},
            (max @$d[1,3]) / $self->{sy},
         );

         return unless ($x2-$x1) > 8 && ($y2-$y1) > 8;

         $self->crop ($x1, $y1, $x2, $y2);
      } else {
         return 0;
      }
   }

   1
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

   1
}

sub auto_position {
   my ($self, $w, $h) = @_;

   if ($self->{window}) {
      my ($x, $y) = $self->get_position;
      my $nx = max 0, min $self->{rsw} - $w, $x;
      my $ny = max 0, min $self->{rsh} - $h, $y;
      $self->move ($nx, $ny) if $nx != $x || $ny != $y;
   }
}

sub auto_resize {
   my ($self) = @_;

   if ($self->{maxpect}
       || $self->{iw} > $self->{sw}
       || $self->{ih} > $self->{sh}) {
      $self->resize_maxpect;
   } else {
      $self->resize ($self->{iw}, $self->{ih});
   }
}

=item $img->resize_maxpect

Resize the image so it is maximally large.

=cut

sub resize_maxpect {
   my ($self) = @_;

   my ($w, $h) = (int ($self->{iw} * $self->{sh} / $self->{ih}),
                  int ($self->{sh}));
   ($w, $h) = ($self->{sw}, $self->{ih} * $self->{sw} / $self->{iw}) if $w > $self->{sw};

   $self->resize ($w, $h);
}

=item $img->resize ($width, $height)

Resize the image window to the given size.

=cut

sub resize {
   my ($self, $w, $h) = @_;
   
   return unless $self->{window};

   my $w = max (16, min ($self->{rsw}, $w));
   my $h = max (16, min ($self->{rsh}, $h));

   $self->{dw} = $w;
   $self->{dh} = $h;

   $self->auto_position ($w, $h);
   $self->{window}->resize ($w, $h);

   $self->redraw;
}

=item $img->uncrop

Undo any cropping; Show the full image.

=cut

sub uncrop {
   my ($self) = @_;

   $self->set_subimage ($self->{image});
}

=item $img->crop ($x1, $y1, $x2, $y2)

Crop the image to the specified rectangle.

=cut

sub crop {
   my ($self, $x1, $y1, $x2, $y2) = @_;

   my $w = max ($x2 - $x1, 1);
   my $h = max ($y2 - $y1, 1);

   $self->set_subimage (
      $self->{subimage}->new_subpixbuf ($x1, $y1, $w, $h)
   );
}

sub update_mplayer_window {
   my ($self) = @_;

   # force a resize of the mplayer window, otherwise it doesn't receive
   # a configureevent :/
   $self->{mplayer_window}->window->resize (1, 1),
   $self->{mplayer_window}->window->resize ($self->{w}, $self->{h})
      if $self->{mplayer_window}
         && $self->{mplayer_window}->window;
}

sub do_configure {
   my ($self, $event) = @_;

   my $window = $self->window;

   my ($sw, $sh) = ($self->{sw}, $self->{sh});

   my ($x, $y) = ($event->x    , $event->y     );
   my ($w, $h) = ($event->width, $event->height);

   $self->{w} = $w;
   $self->{h} = $h;

   $self->update_mplayer_window;

   return unless $self->{subimage};

   $w = max (16, $w);
   $h = max (16, $h);

   return if $self->{dw} == $w && $self->{dh} == $h;

   $self->{dw} = $w;
   $self->{dh} = $h;

   $self->schedule_redraw;
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

      } elsif ($key == $Gtk2::Gdk::Keysyms{M}) {
         if ($self->{rsw} == $self->{sw} && $self->{rsh} == $self->{sh}) {
            ($self->{sw}, $self->{sh}) = ($self->{dw},  $self->{dh});
         } else {
            ($self->{sw}, $self->{sh}) = ($self->{rsw}, $self->{rsh});
         }

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
         $self->force_redraw; $self->redraw;

      } elsif ($key == $Gtk2::Gdk::Keysyms{s}) {
         $self->{interp} = 'bilinear';
         $self->force_redraw; $self->redraw;

      } elsif ($key == $Gtk2::Gdk::Keysyms{S}) {
         $self->{interp} = 'hyper';
         $self->force_redraw; $self->redraw;

      } elsif ($key == $Gtk2::Gdk::Keysyms{t}) {
         $self->set_subimage (Gtk2::CV::rotate $self->{subimage}, 270);

      } elsif ($key == $Gtk2::Gdk::Keysyms{T}) {
         $self->set_subimage (Gtk2::CV::rotate $self->{subimage},  90);

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

   $self->{window}->process_updates (1);
   $self->{window}->get_screen->get_display->sync;
   Gtk2->main_iteration while Gtk2->events_pending;

   $self->redraw;
}

sub force_redraw {
   my ($self) = @_;

   $self->{dw_} = -1;
}

sub redraw {
   my ($self) = @_;

   return unless $self->{window} && $self->{window}->is_visible;

   # delay resizing iff we expect the wm to set frame extents later
   return if !$self->{frame_extents}
             && Gtk2::CV::gdk_net_wm_supports $self->{frame_extents_property};

   # delay if redraw pending
   return if $self->{refresh};

   # skip if no work to do
   return if $self->{dw_} == $self->{dw}
          && $self->{dh_} == $self->{dh};

   $self->{window}->set_back_pixmap (undef, 0);

   ($self->{dw_}, $self->{dh_}) = ($self->{dw}, $self->{dh});

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
                     Gtk2::CV::dealpha $pb,
                     0, 0, 0, 0, $self->{dw}, $self->{dh},
                     "normal", 0, 0);

   $self->{window}->set_back_pixmap ($pm);
   $self->{window}->clear_area (0, 0, $self->{dw}, $self->{dh});

   $self->draw_drag_rect;

   $self->{window}->process_updates (1);
   $self->{window}->get_screen->get_display->sync;
}

=back

=head1 AUTHOR

Marc Lehmann <schmorp@schmorp.de>

=cut

1


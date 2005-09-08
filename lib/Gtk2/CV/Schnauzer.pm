=head1 NAME

Gtk2::CV::Schnauzer - a widget for displaying image collections

=head1 SYNOPSIS

  use Gtk2::CV::Schnauzer;

=head1 DESCRIPTION

=head2 METHODS

=over 4

=cut

package Gtk2::CV::Schnauzer::DrawingArea;

use Glib::Object::Subclass Gtk2::DrawingArea,
   signals => { size_allocate => \&Gtk2::CV::Schnauzer::do_size_allocate_rounded };

package Gtk2::CV::Schnauzer;

use integer;

use Gtk2;
use Gtk2::Pango;
use Gtk2::Gdk::Keysyms;

use Gtk2::CV;

use Glib::Object::Subclass
   Gtk2::VBox,
   signals => {
      activate          => { flags => [qw/run-first/], return_type => undef, param_types => [Glib::String] },
      popup             => { flags => [qw/run-first/], return_type => undef, param_types => [Gtk2::Menu, Glib::Scalar, Gtk2::Gdk::Event] },
      popup_selected    => { flags => [qw/run-first/], return_type => undef, param_types => [Gtk2::Menu, Glib::Scalar] },
      selection_changed => { flags => [qw/run-first/], return_type => undef, param_types => [Glib::Scalar] },
      chpaths           => { flags => [qw/run-first/], return_type => undef, param_types => [Glib::Scalar] },
      chdir             => { flags => [qw/run-first/], return_type => undef, param_types => [Glib::String] },
   };

use List::Util qw(min max);

use File::Spec;
use File::Copy;
use File::Temp;
use Cwd ();

use POSIX qw(ceil ENOTDIR _exit strftime);

use Fcntl;
use IO::AIO;

use Gtk2::CV::Jobber;

use base Gtk2::CV::Jobber::Client;

use strict;

my %dir;
my $dirid;

sub regdir($) {
   $dir{$_[0]} ||= ++$dirid;
}

my $curdir = File::Spec->curdir;
my $updir  = File::Spec->updir;

sub IW() { 80 } # must be the same as in CV.xs(!)
sub IH() { 60 } # must be the same as in CV.xs(!)
sub IX() { 20 }
sub IY() { 16 }
sub FY() { 12 } # font-y

sub SCROLL_Y()    { 1  }
sub PAGE_Y()      { 20 }
sub SCROLL_TIME() { 150 }

# entries are arrays in this format:
# [0] dir
# [1] file
# [2] Gtk2::Pixmap, or thumb file
# [3] cached short filename

sub img {
   my $pb = Gtk2::CV::require_image $_[0];

   my $pm = scalar $pb->render_pixmap_and_mask (0.5);
   my $w  = $pb->get_width;
   my $h  = $pb->get_height;

   [
      $pm,
      (IW - $w) * 0.5, (IH - $h) * 0.5,
      $w, $h
   ]
}

my %ext_logo = (
   jpeg => "jpeg",
   jfif => "jpeg",
   jpg  => "jpeg",
   jpe  => "jpeg",
   png  => "png",
   gif  => "gif",
   tif  => "tif",
   tiff => "tif",

   mpeg => "mpeg",
   mpg  => "mpeg",
   mpv  => "mpeg",
   mpa  => "mpeg",
   mpe  => "mpeg",
   m1v  => "mpeg",
   mp4  => "mpeg",
   
   mov  => "mov",
   qt   => "mov",

   avi  => "avi",
   wmv  => "wmv",
   asf  => "asf",

   rm   => "rm",
   ram  => "rm",

   txt  => "txt",
   csv  => "txt",
   crc  => "txt",

   mid  => "midi",
   midi => "midi",

   rar  => "rar",
   zip  => "zip",
   ace  => "ace",

   par  => "par",
   par2 => "par",
);

my $dir_img  = img "dir.png";
my $file_img = img "file.png";

my %file_img = do {
   my %logo = reverse %ext_logo;

   map +($_ => img "file-$_.png"), keys %logo;
};

# get filename of corresponding xvpic-file
sub xvpic($) {
   $_[0] =~ m%^(.*/)?([^/]+)$%sm
      or Carp::croak "FATAL: unable to split <$_[0]> into dirname/basename";
   "$1.xvpics/$2"
}

sub dirname($) {
   $_[0] =~ m%^(.*)/[^/]+%sm
      ? $1
      : $curdir
}

# filename => extension
sub extension {
   $_[0] =~ /\.([a-z0-9]{3,4})[\.\-_0-9~]*$/i
      ? lc $1 : ();
}

sub read_thumb {
   if (my $pb = eval { Gtk2::CV::load_jpeg Glib::filename_from_unicode $_[0] }) {
      return [-1, -1, Gtk2::CV::dealpha $pb];
   } elsif (open my $p7, "<:raw", Glib::filename_from_unicode $_[0]) {
      if (<$p7> =~ /^P7 332/) {
         1 while ($_ = <$p7>) =~ /^#/;
         if (/^(\d+)\s+(\d+)\s+255/) {
            local $/;
            return [$1, $2, <$p7>];
         }
      }
   }

   ();
}

# generate a thumbnail for a file
Gtk2::CV::Jobber::define gen_thumb =>
   pri   => -1000,
   read  => 1,
   fork  => 1,
sub {
   my ($job) = @_;
   my $path = $job->{path};

   delete $job->{data};

   eval {
      die "can only generate thumbnail for regular files"
         unless Fcntl::S_ISREG ($job->{stat}[2]);

      mkdir Glib::filename_from_unicode +(dirname $path) . "/.xvpics", 0777;

      my $pb = eval { $path =~ /\.jpe?g$/i && Gtk2::CV::load_jpeg $path, 1 }
               || eval { new_from_file Gtk2::Gdk::Pixbuf $path }
               || Gtk2::CV::require_image "error.png";

      my ($w, $h) = ($pb->get_width, $pb->get_height);

      if ($w * IH > $h * IW) {
         $h = int $h * IW / $w + 0.5;
         $w = IW;
      } else {
         $w = int $w * IH / $h + 0.5;
         $h = IH;
      }

      $pb = Gtk2::CV::dealpha $pb->scale_simple ($w, $h, 'tiles');
      $pb->save (Glib::filename_from_unicode xvpic $path, "jpeg", quality => 95);
      $job->{data} = $pb->get_pixels . pack "SSS", $w, $h, $pb->get_rowstride;

      utime $job->{stat}[9], $job->{stat}[9], Glib::filename_from_unicode xvpic $path;
   };

   $job->finish;
};

Gtk2::CV::Jobber::define upd_thumb =>
   pri   => -2000,
   stat  => 1,
sub {
   my ($job) = @_;
   my $path = $job->{path};

   aio_stat Glib::filename_from_unicode xvpic $path, sub {
      Gtk2::CV::Jobber::submit gen_thumb => $path
         unless $job->{stat}[9] == (stat _)[9];

      $job->finish;
   };
};

# remove a file, or move it to the unlink directory
Gtk2::CV::Jobber::define unlink =>
   pri   => 1000,
   class => "stat",
sub {
   my ($job) = @_;

   if (exists $ENV{CV_TRASHCAN}) {
      die "CV_TRASHCAN not implemented yet in the job queue system\n";
#      require File::Copy;
#      mkdir "$ENV{CV_TRASHCAN}/$1" if $path =~ /^(.*)\//s;
#      File::Copy::move "$path", "$ENV{CV_TRASHCAN}/$path"
   } else {
      $Gtk2::CV::Jobber::jobs{$job->{path}} = { }; # no further jobs make sense

      aio_unlink Glib::filename_from_unicode $job->{path}, sub {
         my $status = shift;

         aio_unlink Glib::filename_from_unicode xvpic $job->{path}, sub {
            $job->{data} = $status;
            $job->finish;
         };
      };
   }
};

Gtk2::CV::Jobber::define mv =>
   pri   => -2000,
   stat  => 1,
   class => "read",
   fork  => 1,
sub {
   my ($job) = @_;
   my $path = $job->{path};
   my $dest = $job->{data};

   # TODO: don't use /bin/mv and generate create events.
   system "/bin/mv", "-v", "-b", Glib::filename_from_unicode       $path, Glib::filename_from_unicode "$dest/.";
   system "/bin/mv",       "-b", Glib::filename_from_unicode xvpic $path, Glib::filename_from_unicode "$dest/.xvpics/."
      if -e Glib::filename_from_unicode xvpic $path;
   $job->event (unlink => $path);
#   $job->event (create => $dest);

   $job->finish;
};

sub jobber_update {
   my ($self, $job) = @_;

   #warn "got $job->{path}::$job->{type}\n";#d#

   # update path => index map for faster access
   unless (exists $self->{map}) {
      my %map;

      @map{ map "$_->[0]/$_->[1]", @{$self->{entry}} }
         = (0 .. $#{$self->{entry}});

      $self->{map} = \%map;
   }

   exists $self->{map}{$job->{path}}
      or return; # not for us

   my $idx = $self->{map}{$job->{path}};

   if ($job->{type} eq "unlink") {
      return if $job->{status};

      --$self->{cursor} if $self->{cursor} > $_;

      delete $self->{sel}{$idx};
      splice @{$self->{entry}}, $idx, 1;
      $self->entry_changed;
      $self->invalidate_all;

   } else {
      if ($job->{type} eq "gen_thumb" && exists $job->{data}) {
         my $data = Encode::encode "iso-8859-1", $job->{data};
         my ($w, $h, $rs) = unpack "SSS", substr $data, -6;
         $self->{entry}[$idx][2] = [
            -1,
            -1,
            new_from_data Gtk2::Gdk::Pixbuf $data, 'rgb', 0, 8, $w, $h, $rs
         ];
      }

      $self->draw_entry ($idx);
   }
}

# prefetch a file after a timeout
sub prefetch {
   my ($self, $inc) = @_;

   return unless $self->cursor_valid;

   my $prefetch = $self->{cursor} + $inc;
   return if $prefetch < 0 || $prefetch > $#{$self->{entry}};

   my $e = $self->{entry}[$prefetch];
   $self->{prefetch} = "$e->[0]/$e->[1]";

   remove Glib::Source delete $self->{prefetch_source}
      if $self->{prefetch_source};

   $self->{prefetch_source} = add Glib::Timeout 100, sub {
      my $id = ++$self->{prefetch_aio};
      aio_open Glib::filename_from_unicode $self->{prefetch}, O_RDONLY, 0, sub {
         my $fh = $_[0]
            or return;

         my $ofs = 0;

         $self->{aio_reader} = sub {
            return unless $id == $self->{prefetch_aio};

            aio_read $fh, $ofs, 4096, my $buffer, 0, sub {
               return delete $self->{aio_reader}
                  if $_[0] <= 0 || $ofs > 1024*1024;

               $ofs += 4096;
               $self->{aio_reader}->();
            };
         };

         $self->{aio_reader}->();
      };

      delete $self->{prefetch_source};
      0
   };
}

sub prefetch_cancel {
   my ($self) = @_;

   delete $self->{prefetch};
   delete $self->{prefetch_aio};
}

sub coord {
   my ($self, $event) = @_;

   my $x = $event->x / (IW + IX);
   my $y = $event->y / (IH + IY);

   $x = $self->{cols} - 1 if $x >= $self->{cols};

   (
      (max 0, min $self->{cols} - 1, $x),
      (max 0, min $self->{page} - 1, $y) + $self->{row},
   );
}

sub INIT_INSTANCE {
   my ($self) = @_;

   $self->{cols}  = 1; # just pretend, simplifies code a lot
   $self->{page}  = 1;
   $self->{offs}  = 0;
   $self->{entry} = [];

   $self->push_composite_child;

   $self->pack_start (my $hbox = new Gtk2::HBox, 1, 1, 0);
   $self->pack_start (new Gtk2::HSeparator, 0, 0, 0);
   $self->pack_end   (my $labelwindow = new Gtk2::EventBox, 0, 1, 0);
   $labelwindow->add ($self->{info} = new Gtk2::Label);
   $labelwindow->signal_connect_after (size_request => sub { $_[1]->width (0) });
   # the above 3 lines are just to make the text clip to the window *sigh*
   $self->{info}->set (selectable => 1, xalign => 0, justify => "left");

   $self->signal_connect (destroy => sub { %{$_[0]} = () });

   $hbox->pack_start ($self->{draw}   = new Gtk2::CV::Schnauzer::DrawingArea, 1, 1, 0);
   $hbox->pack_end   ($self->{scroll} = new Gtk2::VScrollbar , 0, 0, 0);

   $self->{adj} = $self->{scroll}->get ("adjustment");

   $self->{adj}->signal_connect (value_changed => sub {
      my $row = int $_[0]->value;

      if (my $diff = $self->{row} - $row) {
         $self->{row} = $row;
         $self->{offs} = $row * $self->{cols};

         if ($self->{window}) {
            if ($self->{page} > abs $diff) {
               if ($diff > 0) {
                  $self->{window}->scroll (0, $diff * (IH + IY));
               } else {
                  $self->{window}->scroll (0, $diff * (IH + IY));
               }
               $self->{window}->process_all_updates;
            } else {
               $self->invalidate_all;
            }
         }
      }

      0
   });

   #$self->{draw}->set_redraw_on_allocate (0); # nope
   $self->{draw}->double_buffered (1);

   $self->{draw}->signal_connect (size_request => sub {
      $_[1]->width  ((IW + IX) * 4);
      $_[1]->height ((IH + IY) * 3);

      1
   });

   $self->{draw}->signal_connect_after (realize => sub {
      $self->{window} = $_[0]->window;

      $self->setadj;
      $self->make_visible ($self->{cursor}) if $self->cursor_valid;

      0
   });

   $self->{draw}->signal_connect (configure_event => sub {
      $self->{width}  = $_[1]->width;
      $self->{height} = $_[1]->height;
      $self->{cols} = ($self->{width}  / (IW + IX)) || 1;
      $self->{page} = ($self->{height} / (IH + IY)) || 1;

      $self->{row} = ($self->{offs} + $self->{cols} / 2) / $self->{cols};
      $self->{offs} = $self->{row} * $self->{cols};

      $self->setadj;

      $self->{adj}->set_value ($self->{row});
      $self->invalidate_all;

      1
   });

   $self->{draw}->signal_connect (expose_event => sub {
      $self->expose ($_[1]);
   });

   $self->{draw}->signal_connect (scroll_event => sub {
      my $dir = $_[1]->direction;

      $self->prefetch_cancel;

      if ($dir eq "down") {
         my $value = $self->{adj}->value + $self->{page};
         $self->{adj}->set_value ($value <= $self->{maxrow} ? $value : $self->{maxrow});
         $self->clear_cursor;

      } elsif ($dir eq "up") {
         my $value = $self->{adj}->value;
         $self->{adj}->set_value ($value >= $self->{page} ? $value - $self->{page} : 0);
         $self->clear_cursor;
         
      } else {
         return 0;
      }

      return 1;
   });

   $self->{draw}->signal_connect (button_press_event => sub {
      my ($x, $y) = $self->coord ($_[1]); 
      my $cursor = $x + $y * $self->{cols};

      $self->prefetch_cancel;

      if ($_[1]->type eq "button-press") {
         if ($_[1]->button == 1) {
            $_[0]->grab_focus;

            delete $self->{cursor};

            unless ($_[1]->state * "shift-mask") {
               $self->clear_selection;
               $self->invalidate_all;
               delete $self->{cursor_current};
               $self->{cursor} = $cursor if $cursor < @{$self->{entry}};
            }

            if ($cursor < @{$self->{entry}} && $self->{sel}{$cursor}) {
               delete $self->{sel}{$cursor};
               delete $self->{sel_x1};

               $self->emit_sel_changed;

               $self->invalidate (
                  (($cursor - $self->{offs}) % $self->{cols},
                   ($cursor - $self->{offs}) / $self->{cols}) x 2
               );
            } else {
               ($self->{sel_x1}, $self->{sel_y1}) =
               ($self->{sel_x2}, $self->{sel_y2}) = ($x, $y);
               $self->{oldsel} = $self->{sel};
               $self->selrect;
            }
         } elsif ($_[1]->button == 3) {
            $self->emit_popup ($_[1],
                               $cursor < @{$self->{entry}} ? $cursor : undef);
         }
      } elsif ($_[1]->type eq "2button-press") { 
         $self->emit_activate ($cursor) if $cursor < @{$self->{entry}};
      }
      1;
   });

   my $scroll_diff; # for drag & scroll

   $self->{draw}->signal_connect (motion_notify_event => sub {
      return unless exists $self->{sel_x1};

      {
         my $y = $_[1]->y;

         if ($y < - PAGE_Y) {
            $scroll_diff = -$self->{page};
         } elsif ($y < - SCROLL_Y) {
            $scroll_diff = -1;
         } elsif ($y > $self->{page} * (IH + IY) + PAGE_Y) {
            $scroll_diff = +$self->{page};
         } elsif ($y > $self->{page} * (IH + IY) + SCROLL_Y) {
            $scroll_diff = +1;
         } else {
            $scroll_diff = 0;
         }

         $self->{scroll_id} ||= add Glib::Timeout SCROLL_TIME, sub {
            my $row = $self->{row} + $scroll_diff;

            $row = max 0, min $row, $self->{maxrow};

            if ($self->{row} != $row) {
               $self->{sel_y2} += $row - $self->{row};
               $self->selrect;
               $self->{adj}->set_value ($row);
            }

            1;
         };
      }

      my ($x, $y) = $self->coord ($_[1]);

      if ($x != $self->{sel_x2} || $y != $self->{sel_y2}) {
         ($self->{sel_x2}, $self->{sel_y2}) = ($x, $y);
         $self->selrect;
      }

      1;
   });

   $self->{draw}->signal_connect (button_release_event => sub {
      delete $self->{oldsel};
      
      remove Glib::Source delete $self->{scroll_id} if exists $self->{scroll_id};

      return unless exists $self->{sel_x1};

      # nop
      1;
   });

   # unnecessary redraws...
   $self->{draw}->signal_connect (focus_in_event  => sub { 1 });
   $self->{draw}->signal_connect (focus_out_event => sub { 1 });

   $self->{draw}->add_events ([qw(button_press_mask button_release_mask button-motion-mask scroll_mask)]);
   $self->{draw}->can_focus (1);

   $self->signal_connect (key_press_event => sub { $self->handle_key ($_[1]->keyval, $_[1]->state) });
   $self->add_events ([qw(key_press_mask key_release_mask)]);

   $self->pop_composite_child;

   $self->jobber_register;
}

sub do_size_allocate_rounded {
   $_[1]->width  ($_[1]->width  / (IW + IX) * (IW + IX));
   $_[1]->height ($_[1]->height / (IH + IY) * (IH + IY));
   $_[0]->signal_chain_from_overridden ($_[1]);
}

sub set_geometry_hints {
   my ($self) = @_;

   my $window = $self->get_toplevel
      or return;

   my $hints = new Gtk2::Gdk::Geometry;
   $hints->base_width  (IW + IX); $hints->base_height (IH + IY);
   $hints->width_inc   (IW + IX); $hints->height_inc  (IH + IY);
   $window->set_geometry_hints ($self->{draw}, $hints, [qw(base-size resize-inc)]);
}

sub emit_sel_changed {
   my ($self) = @_;

   my $sel = $self->{sel};

   if (!$sel || !%$sel) {
      $self->{info}->set_text ("");
   } elsif (1 < scalar %$sel) {
      $self->{info}->set_text (sprintf "%d entries selected", scalar %$sel);
   } else {
      my $entry = $self->{entry}[(keys %$sel)[0]];

      my $id = ++$self->{aio_sel_changed};

      aio_stat Glib::filename_from_unicode "$entry->[0]/$entry->[1]", sub {
         return unless $id == $self->{aio_sel_changed};
         $self->{info}->set_text (
            sprintf "%s: %d bytes, last modified %s (in %s)",
                    $entry->[1],
                    -s _,
                    (strftime "%Y-%m-%d %H:%M:%S", localtime +(stat _)[9]),
                    $entry->[0],
         );
      };
   }

   $self->signal_emit (selection_changed => $self->{sel});
}

sub emit_popup {
   my ($self, $event, $cursor) = @_;

#   my $entry = $self->{entry}[$cursor];
#   my $path = "$entry->[0]/$entry->[1]";

   my $menu = new Gtk2::Menu;

   if (exists $self->{dir}) {
      $menu->append (my $i_up = new Gtk2::MenuItem "Parent (^)");
      $i_up->signal_connect (activate => sub {
         $self->set_dir ($self->{dir} . "/" . $updir);
      });
   }

   my @sel = keys %{$self->{sel}};
   @sel = $cursor if !@sel && defined $cursor;

   if (@sel) {
      $menu->append (my $item = new Gtk2::MenuItem "Selected");
      $item->set_submenu (my $sel = new Gtk2::Menu);

      $sel->append (my $item = new Gtk2::MenuItem @sel . " file(s)");
      $item->set_sensitive (0);

      $sel->append (my $item = new Gtk2::MenuItem "Generate Thumbnails (Ctrl-G)");
      $item->signal_connect (activate => sub { $self->generate_thumbnails (@sel) });

      $sel->append (my $item = new Gtk2::MenuItem "Update Thumbnails (Ctrl-U)");
      $item->signal_connect (activate => sub { $self->update_thumbnails (@sel) });

      $sel->append (my $item = new Gtk2::MenuItem "Delete");
      $item->set_submenu (my $del = new Gtk2::Menu);
      $del->append (my $item = new Gtk2::MenuItem "Physically (Ctrl-D)");
      $item->signal_connect (activate => sub { $self->remove (@sel) });

      $self->signal_emit (popup_selected => $menu, \@sel);
   }

   {
      $menu->append (my $item = new Gtk2::MenuItem "Selection");
      $item->set_submenu (my $sel = new Gtk2::Menu);

      $sel->append (my $item = new Gtk2::MenuItem "Expand etc. NYI");
      $item->set_sensitive (0);
   }

   $self->signal_emit (popup => $menu, $cursor, $event);
   $_->show_all for $menu->get_children;
   $menu->popup (undef, undef, undef, undef, $event->button, $event->time);
}

sub emit_activate {
   my ($self, $cursor) = @_;

   $self->prefetch_cancel;

   my $entry = $self->{entry}[$cursor];
   my $path = "$entry->[0]/$entry->[1]";

   $self->{cursor_current} = 1;

   if (-d $path) {
      $self->set_dir ($path);
   } else {
      $self->signal_emit (activate => $path);
   }
}

sub make_visible {
   my ($self, $offs) = @_;

   my $row = $offs / $self->{cols};

   $self->{adj}->set_value ($row < $self->{maxrow} ? $row : $self->{maxrow})
      if $row < $self->{row} || $row >= $self->{row} + $self->{page};
}

sub draw_entry {
   my ($self, $offs) = @_;

   my $row = $offs / $self->{cols};

   if ($row >= $self->{row} and $row < $self->{row} + $self->{page}) {
      $offs -= $self->{offs};
      $self->invalidate (
         ($offs % $self->{cols}, $offs / $self->{cols}) x 2,
      );
   }

}

sub cursor_valid {
   my ($self) = @_;

   my $cursor = $self->{cursor};

   defined $cursor
        && $self->{sel}{$cursor}
        && $cursor < @{$self->{entry}}
        && $cursor >= $self->{offs}
        && $cursor < $self->{offs} + $self->{page} * $self->{cols};
}

sub cursor_move {
   my ($self, $inc) = @_;

   my $cursor = $self->{cursor};
   delete $self->{cursor_current};

   if ($self->cursor_valid) {
      $self->clear_selection;

      my $oldcursor = $cursor;
      
      $cursor += $inc;
      $cursor -= $inc if $cursor < 0 || $cursor >= @{$self->{entry}};

      if ($cursor < $self->{offs}) {
         $self->{adj}->set_value ($self->{row} - 1);
      } elsif ($cursor >= $self->{offs} + $self->{page} * $self->{cols}) {
         $self->{adj}->set_value ($self->{row} + $self->{page});
      }

      $self->invalidate (
         (($oldcursor - $self->{offs}) % $self->{cols},
          ($oldcursor - $self->{offs}) / $self->{cols}) x 2
      );
   } else {
      $cursor = $self->{cursor};

      $self->clear_selection;

      if (!$cursor) {
         if ($inc < 0) {
            $cursor = $self->{offs} + $self->{page} * $self->{cols} - 1;
         } else {
            $cursor = $self->{offs};
            $cursor++ while $cursor < $#{$self->{entry}}
                            && -d "$self->{entry}[$cursor][0]/$self->{entry}[$cursor][1]/$curdir";

         }
      }

      $self->make_visible ($cursor);
   }

   $self->{cursor} = $cursor;
   $self->{sel}{$cursor} = $self->{entry}[$cursor];

   $self->emit_sel_changed;

   $self->invalidate (
      (($cursor - $self->{offs}) % $self->{cols},
       ($cursor - $self->{offs}) / $self->{cols}) x 2
   );
}

sub clear_cursor {
   my ($self) = @_;

   if (defined (my $cursor = delete $self->{cursor})) {
      delete $self->{sel}{$cursor};
      $self->emit_sel_changed;

      $self->draw_entry ($cursor);
   }
}

sub clear_selection {
   my ($self) = @_;

   delete $self->{cursor};

   $self->draw_entry ($_) for keys %{delete $self->{sel} || {}};

   $self->emit_sel_changed;
}

sub get_selection {
   my ($self) = @_;

   $self->{sel};
}

=item $schnauzer->generate_thumbnails (idx[, idx...])

Generate (unconditionally) the thumbnails on the given entries.

=cut

sub generate_thumbnails {
   my ($self, @idx) = @_;

   for (sort { $b <=> $a } @idx) {
      my $e = $self->{entry}[$_];
      Gtk2::CV::Jobber::submit gen_thumb => "$e->[0]/$e->[1]";
      delete $self->{sel}{$_};
   }

   $self->invalidate_all;
   $self->emit_sel_changed;
}

=item $schnauzer->update_thumbnails (idx[, idx...])

Update (if needed) the thumbnails on the given entries.

=cut

sub update_thumbnails {
   my ($self, @idx) = @_;

   for (sort { $b <=> $a } @idx) {
      my $e = $self->{entry}[$_];
      Gtk2::CV::Jobber::submit upd_thumb => "$e->[0]/$e->[1]";
      delete $self->{sel}{$_};
   }

   $self->invalidate_all;
   $self->emit_sel_changed;
}

=item $schnauzer->remove (idx[, idx...])

Physically delete the given entries.

=cut

sub remove {
   my ($self, @idx) = @_;

   for (sort { $b <=> $a } @idx) {
      my $e = $self->{entry}[$_];
      Gtk2::CV::Jobber::submit unlink => "$e->[0]/$e->[1]";

      --$self->{cursor} if $self->{cursor} > $_;
      delete $self->{sel}{$_};
      splice @{$self->{entry}}, $_, 1, ();
   }

   $self->entry_changed;
   $self->setadj;

   $self->emit_sel_changed;
   $self->invalidate_all;
}

sub handle_key {
   my ($self, $key, $state) = @_;

   $self->prefetch_cancel;

   if ($state * "control-mask") {
      if ($key == $Gtk2::Gdk::Keysyms{g}) {
         my @sel = keys %{$self->{sel}};
         $self->generate_thumbnails (@sel ? @sel : 0 .. $#{$self->{entry}});
      } elsif ($key == $Gtk2::Gdk::Keysyms{a}) {
         $self->select_all;
      } elsif ($key == $Gtk2::Gdk::Keysyms{A}) {
         $self->select_range ($self->{offs}, $self->{offs} + $self->{cols} * $self->{page} - 1);
      } elsif ($key == $Gtk2::Gdk::Keysyms{s}) {
         $self->rescan;
      } elsif ($key == $Gtk2::Gdk::Keysyms{d}) {
         $self->remove (keys %{$self->{sel}});
      } elsif ($key == $Gtk2::Gdk::Keysyms{u}) {
         my @sel = keys %{$self->{sel}};
         $self->update_thumbnails (@sel ? @sel : 0 .. $#{$self->{entry}});
      } elsif ($key == $Gtk2::Gdk::Keysyms{space}) {
         $self->cursor_move (1) if $self->{cursor_current} || !$self->cursor_valid;
         $self->emit_activate ($self->{cursor}) if $self->cursor_valid;
         $self->prefetch (1);
      } elsif ($key == $Gtk2::Gdk::Keysyms{BackSpace}) {
         $self->cursor_move (-1);
         $self->emit_activate ($self->{cursor}) if $self->cursor_valid;
         $self->prefetch (-1);

      } else {
         return 0;
      }
   } else {
      if ($key == $Gtk2::Gdk::Keysyms{Page_Up}) {
         my $value = $self->{adj}->value;
         $self->{adj}->set_value ($value >= $self->{page} ? $value - $self->{page} : 0);
         $self->clear_cursor;
      } elsif ($key == $Gtk2::Gdk::Keysyms{Page_Down}) {
         my $value = $self->{adj}->value + $self->{page};
         $self->{adj}->set_value ($value <= $self->{maxrow} ? $value : $self->{maxrow});
         $self->clear_cursor;

      } elsif ($key == $Gtk2::Gdk::Keysyms{Home}) {
         $self->{adj}->set_value (0);
         $self->clear_cursor;
      } elsif ($key == $Gtk2::Gdk::Keysyms{End}) {
         $self->{adj}->set_value ($self->{maxrow});
         $self->clear_cursor;

      } elsif ($key == $Gtk2::Gdk::Keysyms{Up}) {
         $self->cursor_move (-$self->{cols});
      } elsif ($key == $Gtk2::Gdk::Keysyms{Down}) {
         $self->cursor_move (+$self->{cols});
      } elsif ($key == $Gtk2::Gdk::Keysyms{Left}) {
         $self->cursor_move (-1);
      } elsif ($key == $Gtk2::Gdk::Keysyms{Right}) {
         $self->cursor_move (+1);

      } elsif ($key == $Gtk2::Gdk::Keysyms{Return}) {
         $self->cursor_move (0) unless $self->cursor_valid;
         $self->emit_activate ($self->{cursor});
      } elsif ($key == $Gtk2::Gdk::Keysyms{space}) {
         $self->cursor_move (1) if $self->{cursor_current} || !$self->cursor_valid;
         $self->emit_activate ($self->{cursor}) if $self->cursor_valid;
         $self->prefetch (1);
      } elsif ($key == $Gtk2::Gdk::Keysyms{BackSpace}) {
         $self->cursor_move (-1);
         $self->emit_activate ($self->{cursor}) if $self->cursor_valid;
         $self->prefetch (-1);

      } elsif ($key == ord '^') {
         $self->set_dir ($self->{dir} . "/" . $updir) if exists $self->{dir};

      } elsif (($key >= (ord '0') && $key <= (ord '9'))
               || ($key >= (ord 'a') && $key <= (ord 'z'))) {

         $key = chr $key;

         my ($idx, $cursor) = (0, 0);

         $self->clear_selection;

         for my $entry (@{$self->{entry}}) {
            $idx++;
            $cursor = $idx if $key gt lcfirst $entry->[1];
         }

         if ($cursor < @{$self->{entry}}) {
            delete $self->{cursor_current};
            $self->{sel}{$cursor} = $self->{entry}[$cursor];
            $self->{cursor} = $cursor;

            $self->{adj}->set_value (min $self->{maxrow}, $cursor / $self->{cols});
            $self->emit_sel_changed;
            $self->invalidate_all;
         }
      } else {
         return 0;
      }
   }

   1;
}

sub invalidate {
   my ($self, $x1, $y1, $x2, $y2) = @_;

   return unless $self->{window};

   $self->{draw}->queue_draw_area (
      $x1 * (IW + IX), $y1 * (IH + IY),
      ($x2 - $x1) * (IW + IX) + (IW + IX), ($y2 - $y1) * (IH + IY) + (IH + IY),
   );
}

sub invalidate_all {
   my ($self) = @_;

   $self->invalidate (0, 0, $self->{cols} - 1, $self->{page} - 1);
}

sub select_range {
   my ($self, $a, $b) = @_;

   for ($a .. $b) {
      next if 0 > $_ || $_ > $#{$self->{entry}};

      $self->{sel}{$_} = $self->{entry}[$_];
      $self->draw_entry ($_);
   }

   $self->emit_sel_changed;
}

sub select_all {
   my ($self) = @_;

   $self->select_range (0, $#{$self->{entry}});
}

=item $schnauer->entry_changed

This method needs to be called whenever the C<< $schnauzer->{entry} >>
member has been changed in any way.

=cut

sub entry_changed {
   my ($self) = @_;

   delete $self->{map};
}

sub selrect {
   my ($self) = @_;

   return unless $self->{oldsel};

   my ($x1, $y1) = ($self->{sel_x1}, $self->{sel_y1});
   my ($x2, $y2) = ($self->{sel_x2}, $self->{sel_y2});

   my $prev = $self->{sel};
   $self->{sel} = { %{$self->{oldsel}} };

   if (0) {
      # rectangular selection
      ($x1, $x2) = ($x2, $x1) if $x1 > $x2;
      ($y1, $y2) = ($y2, $y1) if $y1 > $y2;

      outer:
      for my $y ($y1 .. $y2) {
         my $idx = $y * $self->{cols};
         for my $x ($x1 .. $x2) {
            my $idx = $idx + $x;
            last outer if $idx > $#{$self->{entry}};

            $self->{sel}{$idx} = $self->{entry}[$idx];
         }
      }
   } else {
      # range selection
      my $a = $x1 + $y1 * $self->{cols};
      my $b = $x2 + $y2 * $self->{cols};

      ($a, $b) = ($b, $a) if $a > $b;

      for my $idx ($a .. $b) {
         last if $idx > $#{$self->{entry}};
         $self->{sel}{$idx} = $self->{entry}[$idx];
      }
   }

   $self->emit_sel_changed;
   for my $idx (keys %{$self->{sel}}) {
      $self->draw_entry ($idx) if !exists $prev->{$idx};
   }
   for my $idx (keys %$prev) {
      $self->draw_entry ($idx) if !exists $self->{sel}{$idx};
   }
}

sub setadj {
   my ($self) = @_;

   no integer;

   $self->{rows} = ceil @{$self->{entry}} / $self->{cols};
   $self->{maxrow} = $self->{rows} - $self->{page};

   $self->{adj}->step_increment (1);
   $self->{adj}->page_size      ($self->{page});
   $self->{adj}->page_increment ($self->{page});
   $self->{adj}->lower          (0);
   $self->{adj}->upper          ($self->{rows});
   $self->{adj}->changed;

   $self->{adj}->set_value ($self->{maxrow})
      if $self->{row} > $self->{maxrow};
}

sub expose {
   my ($self, $event) = @_;

   no integer;

   return unless @{$self->{entry}};

   my ($x1, $y1, $x2, $y2) = $event->area->values;

   $self->{window}->clear_area ($x1, $y1, $x2, $y2);

   $x2 += $x1 + IW + IX;
   $y2 += $y1 + IH + IY;
   $x1 -= IW + IX;
   $y1 -= IH + IY;

   my @x = map $_ * (IW + IX) + IX / 2, 0 .. $self->{cols} - 1;
   my @y = map $_ * (IH + IY)         , 0 .. $self->{page} - 1;

   # 'orrible, why do they deprecate _convinience_ functions? :(
   my $context = $self->get_pango_context;
   my $font = $context->get_font_description;

   $font->set_absolute_size (FY * Gtk2::Pango->scale);

   my $maxwidth = IW + IX * 0.85;
   my $idx = $self->{offs} + 0;

   my $layout = new Gtk2::Pango::Layout $context;
   $layout->set_ellipsize ('end');
   $layout->set_width ($maxwidth * Gtk2::Pango->scale);

outer:
   for my $y (@y) {
      for my $x (@x) {
         if ($y >= $y1 && $y < $y2
             && $x >= $x1 && $x < $x2) {
            my $entry = $self->{entry}[$idx];
            my $text_gc;

            # selected?
            if (exists $self->{sel}{$idx}) {
               $self->{window}->draw_rectangle ($self->style->black_gc, 1,
                       $x - IX * 0.5, $y, IW + IX, IH + IY);
               $text_gc = $self->style->white_gc;
            } else {
               $text_gc = $self->style->black_gc;
            }

            if (exists $Gtk2::CV::Jobber::jobs{"$entry->[0]/$entry->[1]"}) {
               $self->{window}->draw_rectangle ($self->style->dark_gc ('normal'), 1,
                       $x - IX * 0.4, $y, IW + IX * 0.8, IH);
            }

            # pre-render thumb into pixmap
            unless (ref $entry->[2] && ref $entry->[2][0]) {
               if ($entry->[2]) {
                  my ($pm, $w, $h);

                  my $pb = ref $entry->[2][2]
                           ? $entry->[2][2]
                           : p7_to_pb @{$entry->[2]};

                  $pm = $pb->render_pixmap_and_mask (0.5);
                  ($w, $h) = ($pb->get_width, $pb->get_height);

                  $entry->[2] = [
                     $pm,
                     (IW - $w) * 0.5, (IH - $h) * 0.5,
                     $w, $h,
                  ];
               } else {
                  $entry->[2] = $file_img{ $ext_logo{ extension $entry->[1] } }
                                || $file_img;
               }

            }

            $self->{window}->draw_drawable ($self->style->white_gc,
                     $entry->[2][0],
                     0, 0,
                     $x + $entry->[2][1],
                     $y + $entry->[2][2],
                     $entry->[2][3],
                     $entry->[2][4]);

            $layout->set_text ($entry->[1]);
            my ($w, $h) = $layout->get_pixel_size;

            $self->{window}->draw_layout (
               $text_gc,
               $x + (IW - $w) *0.5, $y + IH,
               $layout
            );
         }

         last outer if ++$idx >= @{$self->{entry}};
      }
   }

   1;
}

sub do_activate {
   # nop
}

sub do_chpaths {
   my ($self, $paths) = @_;

   Gtk2::CV::Jobber::inhibit {
      my $base = $self->{dir};

      delete $self->{cursor};
      delete $self->{sel};
      delete $self->{map};
      $self->{entry} = [];
      $self->entry_changed;

      $self->emit_sel_changed;

      my %exclude = ($curdir => 0, $updir => 0, ".xvpics" => 0);

      my %xvpics;
      my $leaves = -1;

      if (defined $base) {
         $leaves = (stat $base)[3];
         $leaves -= 2; # . and ..

         if (opendir my $fh, Glib::filename_from_unicode "$base/.xvpics") {
            $leaves--; # .xvpics
            $xvpics{Glib::filename_to_unicode $_}++ while defined ($_ = readdir $fh);
         }

         # try stat'ing entries that look like directories first
         my (@d, @f);
         for (@$paths) {
            $_->[1] =~ /\./ ? push @f, $_ : push @d, $_
         }

         push @d, @f;
         $paths = \@d;
      }

      my $progress = new Gtk2::CV::Progress title => "scanning...", work => scalar @$paths;

      my (@d, @f);

      for my $e (@$paths) {
         my ($dir, $file) = @$e;

         if (exists $exclude{$file}) {
            # ignore
            $progress->increment;
         } elsif ($base eq $dir ? exists $xvpics{$file} : -r "$dir/.xvpics/$file") {
            delete $xvpics{$file};
            push @f, [$dir, $file, read_thumb "$dir/.xvpics/$file"];
            $progress->increment;
         } elsif ($leaves) {
            # this is faster than a normal stat on many modern filesystems
            aio_stat Glib::filename_from_unicode "$dir/$file/$curdir", sub {
               if (!$_[0]) { # no error
                  aio_lstat Glib::filename_from_unicode "$dir/$file", sub {
                     if (-d _) {
                        $leaves--;
                        push @d, [$dir, $file, $dir_img, undef];
                     } else {
                        push @f, [$dir, $file, undef, undef];
                     }
                     $progress->increment;
                  };
               } elsif ($! == ENOTDIR) {
                  push @f, [$dir, $file, undef, undef];
                  $progress->increment;
               } else {
                  # does not exist:
                  # ELOOP, ENAMETOOLONG => symlink pointing nowhere
                  # ENOENT => entry does not even exist
                  # EACCESS, EIO, EOVERFLOW => we have to give up
                  $progress->increment;
               }
            };
         } else {
            push @f, [$dir, $file, undef, undef];
            $progress->increment;
         }
      }

      IO::AIO::poll while $progress->inprogress;

      $progress->set_title ("sorting...");

      for (\@d, \@f) {
         @$_ = map $_->[1],
                    sort { $a->[0] cmp $b->[0] }
                       map [foldcase $_->[1], $_],
                           @$_;
      }

      $self->{entry} = [@d, @f];
      $self->entry_changed;

      $self->{adj}->set_value (0);
      $self->setadj;

      $self->{draw}->queue_draw;

      # remove extraneous .xvpics files (but only after an extra check)
      my $outstanding = scalar keys %xvpics;

      $progress = new Gtk2::CV::Progress title => "clean thumbails...", work => $outstanding;

      for my $file (keys %xvpics) {
         aio_stat Glib::filename_from_unicode "$base/$file", sub {
            $progress->increment;

            rmdir "$base/.xvpics" unless --$outstanding; # try to remove the dir at the end

            return if !$_[0] || -d _;

            aio_unlink Glib::filename_from_unicode "$self->{dir}/.xvpics/$file";
         }
      }
   };
}

sub set_paths {
   my ($self, $paths) = @_;

   $paths = [
      map /^(.*)\/([^\/]*)$/s
             ? [$1, $2]
             : [$curdir, $_],
          @$paths
   ];
 
   delete $self->{dir};
   $self->signal_emit (chpaths => $paths);

   $self->window->property_delete (Gtk2::Gdk::Atom->intern ("_X_CWD", 0))
      if $self->window;
}

sub do_chdir {
   my ($self, $dir) = @_;

   $dir = Glib::filename_to_unicode Cwd::abs_path Glib::filename_from_unicode $dir;

   opendir my $fh, Glib::filename_from_unicode $dir
      or die "$dir: $!";

   $self->realize;
   $self->window->property_change (
      Gtk2::Gdk::Atom->intern ("_X_CWD", 0),
      Gtk2::Gdk::Atom->intern ("UTF8_STRING", 0),
      Gtk2::Gdk::CHARS, 'replace',
      Encode::encode_utf8 $dir,
   );

   $self->{dir} = $dir;
   $self->signal_emit (chpaths => [map eval { [$dir, Glib::filename_to_unicode $_] }, readdir $fh]);
}

sub set_dir {
   my ($self, $dir) = @_;

   $self->signal_emit (chdir => $dir);
}

sub get_paths {
   my ($self) = @_;

   [ map "$_->[0]/$_->[1]", @{$self->{entry}} ]
}

sub rescan {
   my ($self) = @_;

   if ($self->{dir}) {
      $self->set_dir ($self->{dir});
   } else {
      $self->set_paths ($self->get_paths);
   }
}

=back

=head1 AUTHOR

Marc Lehmann <schmorp@schmorp.de>

=cut

1


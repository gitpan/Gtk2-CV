package Gtk2::CV::Schnauzer::Cluster;

use Glib::Object::Subclass Gtk2::Window;

use Gtk2::SimpleList;

use Gtk2::CV::Progress;

sub INIT_INSTANCE {
   my ($self) = @_;

   $self->set_default_size (250, 500);

   $self->add (my $sw = new Gtk2::ScrolledWindow);
   $sw->add (
      $self->{list} = new Gtk2::SimpleList
         "#"    => "int",
         "Name" => "text",
   );

   $self->{list}->get_column (0)->set_sort_column_id (0);
   $self->{list}->get_column (1)->set_sort_column_id (1);
   $self->{list}->get_model->set_sort_column_id (0, 'descending');

   $self->{list}->signal_connect (key_press_event => sub {
      my $key = $_[1]->keyval;
      my $state = $_[1]->state;

      my $ctrl = grep $_ eq "control-mask", @{$_[1]->state};

      if ($key == $Gtk2::Gdk::Keysyms{Up}) {
         return 0;
      } elsif ($key == $Gtk2::Gdk::Keysyms{Down}) {
         return 0;
      } else {
         return $self->{schnauzer}->signal_emit (key_press_event => $_[1]);
      }

      1
   });

   $self->{list}->signal_connect (cursor_changed => sub {
      my $row = scalar +($_[0]->get_selection->get_selected_rows)[0]->get_indices;

      my $k = $_[0]{data}[$row][1];
      $k = $self->{cluster}{$k};

      local $self->{updating} = 1;
      $self->{schnauzer}->set_paths ($k);

      1
   });

   $self->signal_connect (destroy => sub {
      if ($self->{signal}) {
         $self->{schnauzer}->signal_handler_disconnect (delete $self->{signal});
      }

      if ($self->{paths}) {
         $self->{schnauzer}->set_paths (delete $self->{paths});
      } else {
         $self->{schnauzer}->set_dir (delete $self->{dir});
      }

      %{$_[0]} = ()
   });
}

sub clusterize {
   my ($self, $files, $regex) = @_;

   \%cluster
}

sub analyse {
   my ($self) = @_;

   my $paths = $self->{schnauzer}->get_paths;

   # remember state
   if (exists $self->{schnauzer}{dir}) {
      $self->{dir} = $self->{schnauzer}{dir};
      delete $self->{paths};
   } else {
      delete $self->{dir};
      $self->{paths} = $paths;
   }

   my $progress = new Gtk2::CV::Progress;

   $self->{_paths} = $paths;
   $self->{select} = [$paths];

   my %files = map {
                      my $orig = $_;
                      s/.*\///;
                      s/(?:-\d+|\.~[~0-9]*)+$//; # remove -000, .~1~ etc.
                      s/\.[^\.]+$//g;
                      s/\.[^.]*//;
                      ($orig => [/(\pL(?:\pL+|\pP(?=\pL))* | \pN+)/gx])
                   }
                   grep !/\.(sfv|crc|par|par2)$/i,
                        @{ $self->{select}[-1] };

   my $cluster = ();

   $progress->update (0.25);

   for my $regex (
      qr/^\PN/,
      qr/^\pN/,
   ) {
      my %c;
      while (my ($k, $v) = each %files) {
         my $idx = 100000;
         # clusterise by component_idx . component
         push @{ $c{$idx++ . $_} }, $k
            for grep m/$regex/, @$v;
      }

      $cluster = { %c, %$cluster };

      for (grep @{ $c{$_} } >= 3, keys %c) {
         delete $files{$_} for @{ $c{$_} };
      }
   }

   $progress->update (0.5);

   $cluster->{"100000REMAINING FILES"} = [keys %files];

   # remove component index
   my %clean;
   while (my ($k, $v) = each %$cluster) {
      $clean{substr $k, 6} = $v;
   }
   $self->{cluster} = \%clean;

   $progress->update (0.75);

   @{ $self->{list}{data} } = (
      sort { $b->[0] <=> $a->[0] }
         grep $_->[0] > 1,
              map [(scalar @{ $self->{cluster}{$_} }), $_], keys %{ $self->{cluster} }
   );
}

sub start {
   my ($self, $schnauzer) = @_;

   $self->{schnauzer} = $schnauzer;

   $self->{signal} = $schnauzer->signal_connect_after (chpaths => sub {
      return if $self->{updating};

      $self->analyse;

      1
   });

   $self->analyse;

   $self->show_all;
}

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

use IO::AIO;

use strict;

my $xvpics = ".xvpics";
my $curdir = File::Spec->curdir;
my $updir  = File::Spec->updir;

sub IW() { 80 } # must be the same as in CV.xs(!)
sub IH() { 60 }
sub IX() { 20 }
sub IY() { 16 }
sub FY() { 12 } # font-y

sub SCROLL_Y()    { 1  }
sub PAGE_Y()      { 20 }
sub SCROLL_TIME() { 150 }

# entries are arrays in this format:
# [0] dir
# [1] file
# [2] thumbnail file
# [3] cached short filename
# [4] Gtk2::Pixmap

sub do_size_allocate_rounded {
   $_[1]->width  ($_[1]->width  / (IW + IX) * (IW + IX));
   $_[1]->height ($_[1]->height / (IH + IY) * (IH + IY));
   $_[0]->signal_chain_from_overridden ($_[1]);
}

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

sub read_p7 {
   if (open my $p7, "<:raw", $_[0]) {
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

sub gen_p7 {
   my ($e) = @_;
 
   eval {
      my $pb = new_from_file Gtk2::Gdk::Pixbuf "$e->[0]/$e->[1]";

      my ($w, $h) = ($pb->get_width, $pb->get_height);

      if ($w * IH > $h * IW) {
         $h = int $h * IW / $w + 0.5;
         $w = IW;
      } else {
         $w = int $w * IH / $h + 0.5;
         $h = IH;
      }

      my $p7 = $pb->scale_simple ($w, $h, 'tiles');

      my $data = pb_to_p7 $p7;

      if (open my $p7, ">:raw", "$e->[0]/$xvpics/$e->[1]") {
         print $p7 "P7 332\n$w $h 255\n" . $data;
         close $p7;

         delete $e->[4];
         $e->[2] = [$w, $h, $data];
      }
   };
}

my %ext_logo = (
   jpeg => "jpeg",
   jfif => "jpeg",
   jpg  => "jpeg",
   png  => "png",
   gif  => "gif",

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
               $self->invalidate (0, 0, $self->{cols} - 1, $self->{page} - 1);
            }
         }
      }

      0;
   });

   #$self->{draw}->set_redraw_on_allocate (0); # nope
   $self->{draw}->double_buffered (1);

   $self->{draw}->signal_connect (size_request => sub {
      $_[1]->width  ((IW + IX) * 4);
      $_[1]->height ((IH + IY) * 3);

      1;
   });

   $self->{draw}->signal_connect_after (realize => sub {
      $self->{window} = $_[0]->window;

      $self->setadj;
      $self->make_visible ($self->{cursor}) if $self->cursor_valid;

      0;
   });

   $self->{draw}->signal_connect (configure_event => sub {
      $self->{width}  = $_[1]->width;
      $self->{height} = $_[1]->height;
      $self->{cols} = ($self->{width}  / (IW + IX)) || 1;
      $self->{page} = ($self->{height} / (IH + IY)) || 1;

      $self->setadj;

      1;
   });

   $self->{draw}->signal_connect (expose_event => sub {
      $self->expose ($_[1]);
   });

   $self->{draw}->signal_connect (scroll_event => sub {
      my $dir = $_[1]->direction;

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

      if ($_[1]->type eq "button-press") {
         if ($_[1]->button == 1) {
            $_[0]->grab_focus;

            delete $self->{cursor};

            unless ($_[1]->state * "shift-mask") {
               $self->clear_selection;
               $self->invalidate (0, 0, $self->{cols} - 1, $self->{rows} - 1);
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

   $self->push_composite_child;
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

      aio_stat "$entry->[0]/$entry->[1]", sub {
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

   # TODO: set cursor to under-pointer if no selection
   if (!$self->cursor_valid && defined $cursor) {
      $self->{cursor} = $cursor;
      $self->cursor_move (0);
   }

   my $menu = new Gtk2::Menu;

   if (exists $self->{dir}) {
      $menu->append (my $i_up = new Gtk2::MenuItem "Up...");
      $i_up->signal_connect (activate => sub {
         $self->set_dir ($self->{dir} . "/" . $updir);
      });
   }

   $menu->append (my $i_up = new Gtk2::MenuItem "Filename clustering...");
   $i_up->signal_connect (activate => sub {
      Gtk2::CV::Schnauzer::Cluster->new->start ($self);
   });

   $self->signal_emit (popup => $menu, $cursor, $event);
   $_->show_all for $menu->get_children;
   $menu->popup (undef, undef, undef, undef, $event->button, $event->time);
}

sub emit_activate {
   my ($self, $cursor) = @_;

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
      delete $self->{sel}{$cursor};
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
                            && -d "$self->{entry}[$cursor][0]/$self->{entry}[$cursor][1]/.";

            $self->make_visible ($cursor);
         }
      }
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

# execute jobs asynchronously, one day
sub job {
   my ($job, $finish) = @_;
   $job->();
   $finish->();
}

sub generate_thumbnail {
   my ($self, $idx) = @_;

   my $entry = delete $self->{sel}{$idx}
      || $self->{entry}[$idx]
      || return;

   my $generation = $self->{generation};

   job sub {
      mkdir "$entry->[0]/$xvpics", 0777;
      gen_p7 $entry;

   }, sub {
      $self->{generation} == $generation
         or return;

      $self->make_visible ($idx);

      $self->draw_entry ($idx);

      $self->emit_sel_changed;

      $self->{window}->process_all_updates;
#   Gtk2::Gdk->flush;
#   Glib::MainContext->iteration (0);
   };
}

sub update_thumbnail {
   my ($self, $idx) = @_;

   my $entry = $self->{entry}[$idx];

   if ((stat "$entry->[0]/$entry->[1]")[9]
       > (stat "$entry->[0]/.xvpics/$entry->[1]")[9]) {
      $self->generate_thumbnail ($idx)
   } elsif (delete $self->{sel}{$idx}) {
      $self->emit_sel_changed;
      $self->draw_entry ($idx);
   }
}

sub handle_key {
   my ($self, $key, $state) = @_;

   if ($state * "control-mask") {
      if ($key == $Gtk2::Gdk::Keysyms{g}) {
         my @sel = keys %{$self->get_selection};
         my $progress = new Gtk2::CV::Progress work => scalar @sel;
         $self->generate_thumbnail ($_), $progress->increment
            for sort { $a <=> $b } @sel;

      } elsif ($key == $Gtk2::Gdk::Keysyms{a}) {
         $self->select_all;
      } elsif ($key == $Gtk2::Gdk::Keysyms{s}) {
         $self->rescan;
      } elsif ($key == $Gtk2::Gdk::Keysyms{d}) {
         $self->delsel;
      } elsif ($key == $Gtk2::Gdk::Keysyms{l}) {
         if (scalar (keys %{$self->{sel}}) > 1) {
           $self->histsort_selected;
         } else {
           $self->histsort_all;
         }
         $self->emit_sel_changed;
      } elsif ($key == $Gtk2::Gdk::Keysyms{u}) {
         my @sel = keys %{ $self->get_selection || {} };
         if (@sel) {
            my $progress = new Gtk2::CV::Progress work => scalar @sel;
            $self->update_thumbnail ($_), $progress->increment
               for sort { $a <=> $b } @sel;
         } else {
            my $progress = new Gtk2::CV::Progress work => scalar @{$self->{entry}};
            $self->update_thumbnail ($_), $progress->increment
               for 0 .. $#{$self->{entry}};
         }

      } elsif ($key == $Gtk2::Gdk::Keysyms{space}) {
         $self->cursor_move (1) if $self->{cursor_current} || !$self->cursor_valid;
         $self->emit_activate ($self->{cursor}) if $self->cursor_valid;
      } elsif ($key == $Gtk2::Gdk::Keysyms{BackSpace}) {
         $self->cursor_move (-1);
         $self->emit_activate ($self->{cursor}) if $self->cursor_valid;

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
      } elsif ($key == $Gtk2::Gdk::Keysyms{BackSpace}) {
         $self->cursor_move (-1);
         $self->emit_activate ($self->{cursor}) if $self->cursor_valid;

      } elsif (($key >= ord('0') && $key <= ord('9'))
               || ($key >= ord('a') && $key <= ord('z'))) {

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
            $self->invalidate (0, 0, $self->{cols} - 1, $self->{page} - 1);
         }
      } else {
         return 0;
      }
   }

   1;
}

sub invalidate {
   my ($self, $x1, $y1, $x2, $y2) = @_;

   $self->{draw}->queue_draw_area (
      $x1 * (IW + IX), $y1 * (IH + IY),
      ($x2 - $x1) * (IW + IX) + (IW + IX), ($y2 - $y1) * (IH + IY) + (IH + IY),
   );
}

sub histsort_all {
   my ($self) = @_;

   my $pics = [];
   my @idx;

   for (0..$#{$self->{entry}}) {
      my $r = pixme ($self->{entry}->[$_]);

      if (defined $r) {
         push @$pics, $r;
         push @idx, $_;
      }
   }

   #print "<(@idx)\n";
   my $sorted_idxs = sort_similar_pics (\@idx, $pics);
   #print ">(@$sorted_idxs)\n";

   my $entrys = $self->{entry};
   $self->{entry} = [];

   for (@$sorted_idxs) {
     push @{$self->{entry}}, $entrys->[$_];
     delete $entrys->[$_];
   }

   for (grep defined, @$entrys) {
     push @{$self->{entry}}, $_;
   }

   $self->invalidate (0, 0, $self->{cols} - 1, $self->{page} - 1);
}

sub histsort_selected {
   my ($self) = @_;

   my $sel = $self->{sel};

   my @idx = sort { $a <=> $b } keys %$sel;
   my $pics = [];
   my @oi;

   for my $i (@idx) {
     my $r = pixme ($self->{entry}->[$i]);
 
     if (defined $r) {
       push @$pics, $self->{entry}->[$i];
       push @oi, $i;
     }
   }
   @idx = @oi;

   my $first_idx = (sort { $a <=> $b } @idx)[0];

   #print "<(@idx)\n";

   my $sorted_idxs = sort_similar_pics (\@idx, $pics);

   #print ">(@$sorted_idxs)\n";

   my $entrys = $self->{entry};
   $self->{entry} = [];
   
   for (my $i = 0; $i < $first_idx; ++$i) {
     $self->{entry}->[$i] = $entrys->[$i];
     delete $entrys->[$i];
   }

   %$sel = ();
   
   for (@$sorted_idxs) {
     push @{$self->{entry}}, $entrys->[$_];
     $sel->{$_} = 1;
     delete $entrys->[$_];
   }

   for (grep defined, @$entrys) {
     push @{$self->{entry}}, $_;
   }

   $self->invalidate (0, 0, $self->{cols} - 1, $self->{page} - 1);
}

#sub histsort_all {
#   my ($self) = @_;
#
#   my @idx;
#   my $pics = [];
#   my $sel = $self->{sel};
#
#   if (scalar (keys %$sel) > 1) {
#      @idx = keys %$sel;
#      my @oi;
#
#      for my $i (@idx) {
#        my $r = pixme ($self->{entry}->[$i]);
#
#        if (defined $r) {
#          push @$pics, $self->{entry}->[$i];
#          push @oi, $i;
#        }
#      }
#      @idx = @oi;
#      %$sel = ();
#   } else {
#}

sub sort_similar_pics {
   my ($idx, $hists) = @_;

   my $hists = make_histogram $hists;

   my ($fh, $datafile) = File::Temp::tempfile;
      for (0 .. $#$idx) {
         print $fh "$idx->[$_]\t" . (join "\t", unpack "f*", $hists->[$_]) . "\n";
      }
   close $fh;

   my ($fh, $rfile) = File::Temp::tempfile;
      print $fh <<EOF;
         library(cluster)
         data <- read.table(file="$datafile", sep="\\t", row.names = 1)
         res <- agnes(data, diss=FALSE, metric = "euclidean")
         write.table(res\$order.lab, file="$datafile", sep="\\t", quote=FALSE, col.names = FALSE,row.names = FALSE)
EOF
   close $fh;

   system "R CMD BATCH --slave --vanilla $rfile /dev/null";

   unlink $rfile;

   open my $fh, "<", $datafile
      or die "$datafile: $!";
   $idx = [ do { local $/; split /\n/, <$fh> } ];

   unlink $datafile;
   
   return $idx;

   my @outidx;
   my $last_idx  = shift @$idx; 
   my $last_hist = shift @$hists;

   push @outidx, $last_idx;

   #print "sorting ...\n";

   while (@$hists) {
      my $i = find_similar ($last_hist, @$hists);
      
      push @outidx, $idx->[$i];
      
      $last_hist = splice (@$hists, $i, 1);
      $last_idx  = splice (@$idx,   $i, 1);
   }

   #print "finished\n";

   return [ @outidx ];
}

sub find_similar {
   my ($hist, @hists) = @_;
 
   no integer;

   my $i = 0;
   my $sim;
   my $min = 1E38; 
   my $minidx = 0;
   
   for (@hists) {
      my $r = compare ($hist, $_);
      if ($r < $min) {
         $min = $r;
         $minidx = $i;
      }
      $i++;
   }
 
   return $minidx;
}

sub compare {
   my ($hist1, $hist2) = @_;

   my @a = unpack "C*", $hist1;
   my @b = unpack "C*", $hist2;

   my $c;
   for (0..$#a) {
     $c += ($a[$_] - $b[$_]) ** 2;
   }

   return $c;
}

sub pixme {
   my ($entry) = @_;
   my $str;

   return undef if not defined $entry;
  
   if (defined $entry->[2]) {
      return $entry->[2]->[2];
    
   } else {
      return undef
         unless defined $entry->[4];
      return undef 
         unless defined $entry->[4]->[0];

      my $pb = Gtk2::Gdk::Pixbuf::get_from_drawable (undef, $entry->[4]->[0], undef, 0, 0, 0, 0, -1, -1);
      return $pb->get_pixels;
   }
}

sub select_all {
   my ($self) = @_;

   for (0 .. $#{$self->{entry}}) {
      $self->{sel}{$_} = $self->{entry}[$_];
      $self->draw_entry ($_);
   }

   $self->emit_sel_changed;
}

# remove a file, or move it to the unlink directory
sub remove_file {
   my ($prefix, $path) = @_;

   if (exists $ENV{CV_TRASHCAN}) {
      require File::Copy;

      mkdir "$ENV{CV_TRASHCAN}/$1" if $path =~ /^(.*)\//s;

      File::Copy::move "$prefix/$path", "$ENV{CV_TRASHCAN}/$path"
   } else {
      unlink "$prefix/$path"
   }
}

sub delsel {
   my ($self) = @_;

   my $sel = delete $self->{sel};
   my @idx = sort { $a <=> $b } keys %$sel;

   my $progress = new Gtk2::CV::Progress work => scalar @idx;

   for (reverse @idx) {
      my $e = $self->{entry}[$_];
      remove_file $e->[0], "$e->[1]"
         or (! -e "$e->[0]/$e->[1]")
         or next;
      remove_file $e->[0], ".xvpics/$e->[1]";
      $self->{cursor}-- if $self->{cursor} > $_;
      splice @{$self->{entry}}, $_, 1, ();

      $progress->increment;
   }

   $self->setadj;
   $self->emit_sel_changed;
   $self->{window}->invalidate_rect (new Gtk2::Gdk::Rectangle (0, 0, $self->{window}->get_size), 1);
}

sub selrect {
   my ($self) = @_;

   return unless $self->{oldsel};

   my ($x1, $y1) = ($self->{sel_x1}, $self->{sel_y1});
   my ($x2, $y2) = ($self->{sel_x2}, $self->{sel_y2});

   my $prev = $self->{sel};
   $self->{sel} = { %{$self->{oldsel}} };

   if (0) {
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

# filename => extension
sub extension {
   $_[0] =~ /\.([a-z0-9]{3,4})[\.\-_0-9~]*$/i
      ? lc $1 : ();
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

   my $layout = new Gtk2::Pango::Layout $context;
   my $maxwidth = IW + IX - IY * 0.1;
   my $idx = $self->{offs} + 0;

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

            # pre-render thumbnail into pixmap
            $entry->[4] ||= do {
               my ($pm, $w, $h);

               my $pb = &p7_to_pb(@{delete $entry->[2]});
               $pm = $pb->render_pixmap_and_mask (0.5);
               ($w, $h) = ($pb->get_width, $pb->get_height);

               $entry->[4] = [
                  $pm,
                  (IW - $w) * 0.5, (IH - $h) * 0.5,
                  $w, $h,
               ];
            };

            #use Data::Dumper;
            #print "F:".Dumper($entry)."\n";
            $self->{window}->draw_drawable ($self->style->white_gc,
                     $entry->[4][0],
                     0, 0,
                     $x + $entry->[4][1],
                     $y + $entry->[4][2],
                     $entry->[4][3],
                     $entry->[4][4]);

            # this text-thingy takes a LOT if time, so pre-cache
            my ($w, $h);

            $layout->set_text ($entry->[3] || $entry->[1]);
            ($w, $h) = $layout->get_pixel_size;

            if ($w > $maxwidth) {
               my $name = $entry->[1];

               my $d = (length $name) * (1 - $maxwidth / $w);

               $name =~ s/\..{3,4}$//;

               substr $name, 0.8 * ((length $name) - $d), $d, "\x{2026}";

               while () {
                  $layout->set_text ($name);
                  ($w, $h) = $layout->get_pixel_size;
                  last if $w < $maxwidth;
                  substr $name, 0.8 * length $name, 2, "\x{2026}";
                  
               }

               $entry->[3] = $name;
            }

            $self->{window}->draw_layout ($text_gc,
                     $x + (IW - $w) *0.5, $y + IH, $layout);
         }

         last outer if ++$idx >= @{$self->{entry}};
      }
   }

   1;
}

sub rescan {
   my ($self) = @_;

   $self->do_chpaths ($self->get_paths);
}

sub do_chpaths {
   my ($self, $paths) = @_;

   my $base = $self->{dir};

   delete $self->{cursor};
   delete $self->{sel};
   delete $self->{entry};

   $self->{generation}++;

   $self->emit_sel_changed;

   my (@d, @f);

   my %exclude = ($curdir => 0, $updir => 0, $xvpics => 0);

   my %xvpics;

   if (defined $base) {
      if (opendir my $fh, "$base/$xvpics") {
         $xvpics{$_}++ while defined ($_ = readdir $fh);
      }
   }

   my $progress = new Gtk2::CV::Progress work => scalar @$paths;

   for (@$paths) {
      my ($dir, $file);

      if ($_ =~ /^(.*)\/([^\/]*)$/s) {
         ($dir, $file) = ($1, $2);
      } else {
         ($dir, $file) = ($curdir, $_);
      }
      
      if (exists $exclude{$file}) {
         # ignore
         $progress->increment;
      } elsif ($base eq $dir ? exists $xvpics{$file} : -r "$dir/$xvpics/$file") {
         delete $xvpics{$file};
         push @f, [$dir, $file, read_p7 "$dir/$xvpics/$file"];
         $progress->increment;
      } else {
         # this is faster than a normal stat on many modern filesystems
         aio_stat "$dir/$file/.", sub {
            if (!$_[0]) { # no error
               push @d, [$dir, $file, undef, undef,
                         $dir_img];
            } elsif ($! == ENOTDIR) {
               push @f, [$dir, $file, undef, undef,
                         $file_img{ $ext_logo{ extension $file } }
                            || $file_img];
            } else {
               # does not exist
               # ELOOP => symlink pointing niwhere
               # ENOENT => entry does not even exist
            }
            $progress->increment;
         };
      }
   }

   IO::AIO::poll while $progress->inprogress;

   for (\@d, \@f) {
      @$_ = map $_->[1],
                 sort { $a->[0] cmp $b->[0] }
                    map {
                           (my $key = lc $_->[1]) =~ s/(\d{1,8})/sprintf "%08d", $1/ge;
                           [$key, $_]
                        }
                       @$_;
   }

   $self->{entry} = [@d, @f];

   $self->{adj}->set_value (0);
   $self->setadj;

   $self->{draw}->queue_draw;

   # remove extraneous .xvpics files (but only after an extra check)
   my $outstanding = scalar keys %xvpics;

   for my $file (keys %xvpics) {
      aio_stat "$self->{dir}/$file", sub {
         rmdir "$base/$xvpics" unless --$outstanding; # try to remove the dir at the end

         return if !$_[0] || -d _;

         aio_unlink "$self->{dir}/$xvpics/$file";
      }
   }
}

sub set_paths {
   my ($self, $paths) = @_;

   delete $self->{dir};
   $self->signal_emit (chpaths => $paths);
}

sub do_chdir {
   my ($self, $dir) = @_;

   $dir = Cwd::abs_path $dir;

   opendir my $fh, $dir
      or die "$dir: $!";

   $self->{dir} = $dir;
   $self->signal_emit (chpaths => [map "$dir/" . Glib::filename_to_unicode $_, readdir $fh]);
}

sub set_dir {
   my ($self, $dir) = @_;

   $self->signal_emit (chdir => $dir);
}

sub get_paths {
   my ($self) = @_;

   [ map "$_->[0]/$_->[1]", @{$self->{entry}} ]
}

sub do_activate {
   # nop
}

1


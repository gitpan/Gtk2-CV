package Gtk2::CV::Schnauzer::DrawingArea;

use Glib::Object::Subclass Gtk2::DrawingArea,
   signals => { size_allocate => \&Gtk2::CV::Schnauzer::do_size_allocate_rounded };

package Gtk2::CV::Schnauzer;

use integer;

use Errno ();

use Gtk2;
use Gtk2::Pango;
use Gtk2::Gdk::Keysyms;

use Gtk2::CV;

use Glib::Object::Subclass
   Gtk2::HBox,
   signals => {
      activate => { flags => [qw/run-first/], return_type => undef, param_types => [Glib::String] },
   };

use List::Util qw(min max);

use File::Spec;

use POSIX qw(ceil);

my $xvpics = ".xvpics";
my $curdir = File::Spec->curdir;
my $updir = File::Spec->updir;

sub IW() { 80 } # must be the same as in CV.xs(!)
sub IH() { 60 }
sub IX() { 30 }
sub IY() { 16 }
sub FY() { 11 } # font-y

sub SCROLL_Y() { 1  }
sub PAGE_Y()   { 20 }
sub SCROLL_TIME() { 150 }

sub do_size_allocate_rounded {
   $_[1]->width  ($_[1]->width  / (IW + IX) * (IW + IX));
   $_[1]->height ($_[1]->height / (IH + IY) * (IH + IY));
   $_[0]->signal_chain_from_overridden ($_[1]);
}

sub img {
   my $pb = Gtk2::CV::require_image $_[0];
   (
      scalar $pb->render_pixmap_and_mask (0.5),
      $pb->get_width, $pb->get_height,
   )
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

my @dir_img  = img "dir.png";
my @file_img = img "file.png";

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

   $self->{cols} = 1; # just pretend, simplifies code a lot
   $self->{page} = 1;
   $self->{offs} = 0;

   $self->push_composite_child;

   $self->signal_connect (destroy => sub { %{$_[0]} = () });

   $self->pack_start ($self->{draw}   = new Gtk2::CV::Schnauzer::DrawingArea, 1, 1, 0);
   $self->pack_end   ($self->{scroll} = new Gtk2::VScrollbar , 0, 0, 0);
   
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
                  $self->{window}->scroll (0, $diff * (IH +IY));
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

   $self->{draw}->signal_connect (button_press_event => sub {
      $_[0]->grab_focus;

      my ($x, $y) = $self->coord ($_[1]); 

      my $cursor = $x + $y * $self->{cols};

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

      $self->emit_activate ($cursor)
         if $_[1]->type eq "2button-press";

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

   $self->{draw}->signal_connect (key_press_event => sub { $self->handle_key ($_[1]->keyval, $_[1]->state) });

   # unnecessary redraws...
   $self->{draw}->signal_connect (focus_in_event  => sub { 1 });
   $self->{draw}->signal_connect (focus_out_event => sub { 1 });

   $self->{draw}->add_events ([qw(key_press_mask button_press_mask button_release_mask button-motion-mask)]);
   $self->{draw}->can_focus (1);

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

      $cursor -= $inc if $cursor < 0;
      $cursor -= $inc if $cursor >= @{$self->{entry}};

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
      $self->clear_selection;

      if ($inc < 0) {
         $cursor = $self->{offs} + $self->{page} * $self->{cols} - 1;
      } else {
         $cursor = $self->{offs};
         $cursor++ while $cursor < $#{$self->{entry}}
                         && -d "$self->{entry}[$cursor][0]/$self->{entry}[$cursor][1]/.";

         $self->make_visible ($cursor);
      }
      
   }
   $self->{cursor} = $cursor;
   $self->{sel}{$cursor} = $self->{entry}[$cursor];

   $self->invalidate (
      (($cursor - $self->{offs}) % $self->{cols},
       ($cursor - $self->{offs}) / $self->{cols}) x 2
   );
}

sub clear_cursor {
   my ($self) = @_;

   if (defined (my $cursor = delete $self->{cursor})) {
      delete $self->{sek}{$cursor};
   }
}

sub clear_selection {
   my ($self) = @_;

   delete $self->{cursor};

   $self->draw_entry ($_) for keys %{delete $self->{sel} || {}};
}

sub get_selection {
   my ($self) = @_;

   $self->{sel};
}

sub generate_thumbnail {
   my ($self, $idx) = @_;

   my $entry = delete $self->{sel}{$idx}
      || $self->{entry}[$idx]
      || return;

   $self->make_visible ($idx);

   mkdir "$entry->[0]/$xvpics", 0777;
   gen_p7 $entry;

   $self->draw_entry ($idx);

   $self->{window}->process_all_updates;
   Glib::MainContext->iteration (0);
}

sub update_thumbnail {
   my ($self, $idx) = @_;

   my $entry = $self->{entry}[$idx];

   if ((stat "$entry->[0]/$entry->[1]")[9]
       > (stat "$entry->[0]/.xvpics/$entry->[1]")[9]) {
      $self->generate_thumbnail ($idx)
   } elsif (delete $self->{sel}{$idx}) {
      $self->draw_entry ($idx);
   }
}

sub handle_key {
   my ($self, $key, $state) = @_;

   if ($state >= "control-mask") {
      if ($key == $Gtk2::Gdk::Keysyms{g}) {
         $self->generate_thumbnail ($_)
            for sort { $a <=> $b } keys %{$self->get_selection};

      } elsif ($key == $Gtk2::Gdk::Keysyms{d}) {
         if (my @sel = values %{$self->get_selection}) {
            unlink "$_->[0]/$_->[1]" for @sel;
            $self->rescan;
         }

      } elsif ($key == $Gtk2::Gdk::Keysyms{u}) {
         if (%{$self->get_selection}) {
            $self->update_thumbnail ($_)
               for sort { $a <=> $b } keys %{$self->get_selection};
         } else {
            $self->update_thumbnail ($_)
               for 0 .. $#{$self->{entry}};
         }

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
         $self->emit_activate ($self->{cursor});
      } elsif ($key == $Gtk2::Gdk::Keysyms{BackSpace}) {
         $self->cursor_move (-1);
         $self->emit_activate ($self->{cursor});

      } elsif (($key >= ord('0') && $key <= ord('9'))
               || ($key >= ord('a') && $key <= ord('z'))
               || ($key >= ord('A') && $key <= ord('Z'))) {

         $key = chr $key;

         my ($idx, $cursor) = (0, 0);

         $self->clear_selection;

         for my $entry (@{$self->{entry}}) {
            $idx++;
            $cursor = $idx if $key gt $entry->[1];
         }

         if ($cursor < @{$self->{entry}}) {
            delete $self->{cursor_current};
            $self->{sel}{$cursor} = $self->{entry}[$cursor];
            $self->{cursor} = $cursor;

            $self->{adj}->set_value (min $self->{maxrow}, $cursor / $self->{cols});
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

sub selrect {
   my ($self) = @_;

   my ($x1, $y1) = ($self->{sel_x1}, $self->{sel_y1});
   my ($x2, $y2) = ($self->{sel_x2}, $self->{sel_y2});

   ($x1, $x2) = ($x2, $x1) if $x2 < $x1;
   ($y1, $y2) = ($y2, $y1) if $y2 < $y1;

   my $prev = $self->{sel};
   $self->{sel} = { %{$self->{oldsel}} };

outer:
   for my $y ($y1 .. $y2) {
      my $idx = $y * $self->{cols};
      for my $x ($x1 .. $x2) {
         my $idx = $idx + $x;
         last outer if $idx > $#{$self->{entry}};

         $self->{sel}{$idx} = $self->{entry}[$idx];
      }
   }

   for my $idx (keys %{$self->{sel}}) {
      $self->draw_entry ($idx) if !exists $prev->{$idx};
   }
   for my $idx (keys %$prev) {
      $self->draw_entry ($idx) if !exists $self->{sel}{$idx};
   }
}

sub setadj {
   my ($self) = @_;

   $self->{rows} = ceil @{$self->{entry}} / $self->{cols};

   $self->{adj}->step_increment (1);
   $self->{adj}->page_size      ($self->{page});
   $self->{adj}->page_increment ($self->{page});
   $self->{adj}->lower          (0);
   $self->{adj}->upper          ($self->{rows});

   $self->{adj}->changed;

   $self->{maxrow} = $self->{rows} - $self->{page};

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

   # pango is SOOO extremely broken. the formula below doesn't even work...
   # because there is NO PORTABLE WAY TO SET THE FONT SIZE IN PIXELS
   #$font->set_size (FY * $self->{window}->get_screen->get_height_mm / $self->{window}->get_screen->get_height
   #                    * (72.27 / 25.4) * Gtk2::Pango->scale);
   $font->set_size (FY * 1/96 * 72.27 * Gtk2::Pango->scale);

   my $layout = new Gtk2::Pango::Layout $context;
   my $maxwidth = IW + IX - IY * 0.25;
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

            # pre-render into pixmap
            $entry->[4] ||= do {
               my ($pm, $w, $h);
               if ($entry->[2]) {
                  my $pb = &p7_to_pb(@{delete $entry->[2]});
                  $pm = $pb->render_pixmap_and_mask (0.5);
                  ($w, $h) = ($pb->get_width, $pb->get_height);
               } else {
                  ($pm, $w, $h) = -e "$entry->[0]/$entry->[1]/."
                                  ? @dir_img
                                  : @file_img;
               }

               $entry->[4] = [
                  $pm,
                  (IW - $w) * 0.5, (IH - $h) * 0.5,
                  $w, $h,
               ];
            };

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

               substr $name, 0.5 * ((length $name) - $d), $d, "\x{2026}";

               while () {
                  $layout->set_text ($name);
                  ($w, $h) = $layout->get_pixel_size;
                  last if $w < $maxwidth;
                  substr $name, 0.5 * length $name, 2, "\x{2026}";
                  
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

   $self->set_paths ([map "$_->[0]/$_->[1]", @{$self->{entry}}]);
}

sub set_paths {
   my ($self, $paths) = @_;

   delete $self->{cursor};
   delete $self->{sel};
   delete $self->{entry};

   my (@d, @f);
   my ($dir, $file);

   for my $path (sort @$paths) {
      if ($path =~ /^(.*)\/([^\/]*)$/s) {
         ($dir, $file) = ($1, $2);
      } else {
         ($dir, $file) = ($curdir, $path);
      }

      my $entry = [$dir, $file];

      if ($file eq $curdir || $file eq $xvpics) {
         # skip
      } elsif ($file eq $updir) {
         $entry->[3] = "<parent>";
         unshift @d, $entry;
      } elsif ($entry->[2] = read_p7 "$dir/$xvpics/$file") {
         push @f, $entry;
      } else {
         # this is faster than a normal stat
         if (stat "$path/.") {
            push @d, $entry;
         } elsif ($! == Errno::ENOTDIR) {
            push @f, $entry;
         } else {
            # does not exist
         }
      }
   }

   $self->{entry} = [@d, @f];

   $self->setadj;

   $self->{draw}->queue_draw;
}

sub set_dir {
   my ($self, $dir) = @_;

   $dir = File::Spec->canonpath ($dir);

   opendir my $fh, $dir
      or die "$dir: $!";

   $self->set_paths ([map "$dir/$_", readdir $fh]);
}

sub add_idle {
   my ($self, @jobs) = @_;

   push @{$self->{idle}}, @jobs;

   $self->{idle_id} ||= add Glib::Idle sub {
      if (my $job = shift @{$self->{idle}}) {
         $job->($self);
         1;
      } else {
         delete $self->{idle_id};
         0;
      }
   };
}

sub do_activate {
}

1;

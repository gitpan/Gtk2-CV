package Gtk2::CV::Progress;

use Gtk2;

use Time::HiRes 'time';

sub INITIAL  (){ 0.5 } # initial popup delay
sub INTERVAL (){ 0.2 } # minimum update interval

sub new {
   my $class = shift;

   my $self = bless {
      @_,
   }, $class;

   $self->{work} ||= 1;
   $self->{next} = time + INITIAL;

   $self
}

sub update {
   my ($self, $progress) = @_;

   my $now = time;

   if ($now > $self->{next}) {
      $self->{next} = $now + INTERVAL;

      if (!$self->{window}) {
         $self->{window} = new Gtk2::Window 'toplevel';
         $self->{window}->set (
            window_position => "mouse",
            accept_focus    => 0,
            focus_on_map    => 0,
            decorated       => 0,
            default_width   => 200,
            default_height  => 30,
         );
         $self->{window}->add ($self->{bar} = new Gtk2::ProgressBar);

         $self->{window}->signal_connect (delete_event => sub { $_[0]->hide; 1 });

         $self->{window}->show_all;
         $self->{window}->realize;
         Gtk2->main_iteration_do (1) while !$self->{window}->window->is_viewable;
      }

      $self->{bar}->set_fraction ($progress / $self->{work});

      if ($self->{work} > 1) {
         $self->{bar}->set_text ("$progress / $self->{work}");
      } else {
         $self->{bar}->set_text (sprintf "%2d%%", 100 * $progress / $self->{work});
      }

      Gtk2->main_iteration while Gtk2->events_pending;
   }
}

sub increment {
   my ($self, $inc) = @_;

   $self->update ($self->{cur} += $inc || 1);
}

sub inprogress {
   my ($self) = @_;

   $self->{cur} < $self->{work}
}

sub DESTROY {
   my ($self) = @_;

   $self->{window}->destroy if $self->{window};
}

1


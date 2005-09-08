=head1 NAME

Gtk2::CV::Jobber - a job queue mechanism for Gtk2::CV

=head1 SYNOPSIS

  use Gtk2::CV::Jobber;

=head1 DESCRIPTION

=over 4

=cut

package Gtk2::CV::Jobber;

use Scalar::Util ();
use IO::AIO;

use Gtk2::CV::Progress;

=item %Gtk2::CV::Jobber::job [READ-ONLY]

Global variable containing all jobs, indexed by full path.

=cut

our %jobs;
our @jobs; # global job order

my %type;
my @type; # type order

my $disabled;

my $NUMCPU = qx<grep -c ^processor /proc/cpuinfo> * 1 || 1;

my %class_limit = (
   other => 32,
   stat  => 16,
   read  =>  2,
   fork  => $NUMCPU + 1,
);

my $progress;

sub scheduler {
   return if $disabled;

job:
   while (@jobs) {
      my $path = $jobs[-1];
      my $types = $jobs{$path};

      my @types = keys %$types;

      if (@types) {
         for my $type (@type) {
            next unless exists $types->{$type};

            my $class = $type{$type}{class};

            return unless $class_limit{$class};
            $class_limit{$class}--;

            my $job = bless delete $types->{$type}, Gtk2::CV::Jobber::Job;

            $job->{path} = $path;
            $job->{type} = $type;

            $job->run;

            next job;
         }

         die "FATAL: unknown job type <@types> encountered, aborting.\n";
      } else {
         delete $jobs{pop @jobs};
         $progress->increment;
      }
   }

   undef $progress;
}

=item Gtk2::CV::Jobber::define $type, [option => $value, ...], $cb

Register a new job type identified by $type. The callback will be called
with ($cont, $path, $type), and has to call &$cont once it has finished
processing.

 pri     => number
 read    => wether reading the file contents ahead of time is useful
 stat    => wether stating the object ahead of time is useful
 fork    => (lots of restrictions)
 class   =>
 maxread =>
 cb      => callback

=cut

sub define($@) {
   my ($type, @opt) = @_;

   my $cb = pop @opt;
   my %opt = @opt;

   $opt{cb}    = $cb;
   $opt{type}  = $type;

   $opt{maxread} ||= 1024*1024*2;

   $opt{class}   ||= "fork" if $opt{fork};
   $opt{class}   ||= "read" if $opt{read};
   $opt{class}   ||= "stat" if $opt{stat};
   $opt{class}   ||= "other";

   $type{$type} = \%opt;

   @type = sort { $type{$b}{pri} <=> $type{$a}{pri} } keys %type;
}

=item Gtk2::CV::Jobber::submit $type, $path, $data

Submit a new job of the given type.

=cut

sub submit {
   my ($type, $path, $data) = @_;

   unless (exists $jobs{$path}) {
      $progress ||= new Gtk2::CV::Progress work => 0, title => "Background Queue...";
      $progress->{work}++;
      $progress->update ($progress->{cur});
      push @jobs, $path;
   }

   $jobs{$path}{$type} = { data => $data };

   scheduler;
}

=item Gtk2::CV::Jobber::disable

=item Gtk2::CV::Jobber::enable

=item Gtk2::CV::Jobber::inhibit { ... }

Disable/re-enable execution of background jobs. When disabled, active jobs will finish, but no new
jobs will be started until jobs are enabled again. Calls can be nested.

=cut

sub disable() {
   ++$disabled;
}

sub enable() {
   --$disabled or scheduler;
}

sub inhibit(&) {
   disable;
   eval {
      $_[0]->();
   };
   {
      local $@;
      enable;
   }
   die if $@;
}

=back

=head2 The Gtk2::CV::Jobber::Job class

Layout:

=over 4

=item $job->{type}

The job type.

=item $job->{path}

The full path to the file.

=item $job->{data}

The original user data passed to add.

=item $job->{stat}

And arrayref of statdata if stat is requested for given job class.

=item $job->{fh}

=item $job->{contents}

The open filehandle to the file and the beginning of the file
when reading is requested for the given job class.

=back

Methods:

=over 4

=item $job->finish

Has to be called by the callback when the job has finished.

=cut

my @idle_slave;

sub Gtk2::CV::Jobber::Job::run {
   my ($job) = @_;

   my $type = $type{$job->{type}}
      or die;

   if ($type->{read} && !$job->{fh}) {
      aio_open Glib::filename_from_unicode $job->{path}, O_RDONLY, 0, sub {
         $job->{fh} = $_[0]
            or return $job->finish;
         $job->{stat} = [stat $job->{fh}]; # should be free of cost
         aio_read $job->{fh}, 0, $type->{maxread}, $job->{contents}, 0, sub {
            $job->run;
         };
      };
   } elsif ($type->{stat} && !$job->{stat}) {
      aio_stat Glib::filename_from_unicode $job->{path}, sub {
         $_[0] and return $job->finish; # don't run job if stat error
         $job->{stat} = [stat _];
         $job->run;
      };
   } elsif ($type->{fork}) {
      my $slave = (pop @idle_slave) || new Gtk2::CV::Jobber::Slave;

      $slave->send ($job);
   } else {
      $type->{cb}->($job);
   }
}

sub Gtk2::CV::Jobber::Job::event {
   my ($job, $type, $path, $data, %arg) = @_;

   $arg{type} = $type;
   $arg{path} = $path;
   $arg{data} = $data;

   if (my $slave = $job->{slave}) {
      $slave->event (\%arg);
   } else {
      $_->jobber_update (\%arg)
         for grep $_, values %Gtk2::CV::Jobber::client;
   }
}

sub Gtk2::CV::Jobber::Job::finish {
   my ($job) = @_;

   if (my $slave = delete $job->{slave}) {
      $slave->finish ($job);
   } else {
      unless (delete $job->{event}) {
         my $class = $type{$job->{type}}{class};
         ++$class_limit{$class};

         scheduler;
      }

      $_->jobber_update ($_[0])
         for grep $_, values %Gtk2::CV::Jobber::client;
   }
}

package Gtk2::CV::Jobber::Client;

=back

=head2 The Gtk2::CV::Jobber::Client class

=over 4

=item $self->jobber_register

To be called when creating a new object instance that wants to listen to
jobber updates.

=cut

sub jobber_register {
   my ($self) = @_;

   Scalar::Util::weaken ($Gtk2::CV::Jobber::client{$self} = $self);

   # nuke all invalid references
   delete $Gtk2::CV::Jobber::client{$_}
      for grep !$Gtk2::CV::Jobber::client{$_}, keys %Gtk2::CV::Jobber::client;
}

=item $self->jobber_update ($job)

The given job has finished.

=cut

sub jobber_update {
   my ($self, $job) = @_;
}

package Gtk2::CV::Jobber::Slave;

use Socket ();

sub new {
   my $class = shift;
   my $self = bless { @_ }, $class;

   socketpair $self->{m}, $self->{s}, &Socket::AF_UNIX, &Socket::SOCK_STREAM, &Socket::PF_UNSPEC
      or die "FATAL: socketpair failed\n";

   $self->{pid} = fork;

   if ($self->{pid}) {
      close $self->{s};

      $self->{w} = add_watch Glib::IO fileno $self->{m},
                         in => sub { $self->reply; 1 },
                         undef,
                         &Glib::G_PRIORITY_HIGH;

   } else {
      eval {
         close $self->{m};

         $self->slave;
      };

      warn "slave process died unexpectedly: $@" if $@;

      POSIX::_exit (0);
   }

   $self
}

sub _send {
   my ($self, $fh, $job) = @_;

   $job->{stat} = join "\0", @{ $job->{stat} };

   $job = join "\x{fcc0}", %$job;
   utf8::encode $job;

   syswrite $fh, pack "Na*", (length $job), $job
      or die "FATAL: unable to send job to subprocess";
}

sub _recv {
   my ($self, $fh) = @_;

   my $len;
   do {
      sysread $fh, $len, 4 - (length $len), length $len
         or return;
   } while length $len < 4;

   my $len = unpack "N", $len
      or return;

   my $job;
   do {
      sysread $fh, $job, $len - (length $job), length $job
         or return;
   } while length $job < $len;

   utf8::decode $job;
   my $job = bless { split /\x{fcc0}/, $job }, Gtk2::CV::Jobber::Job;

   $job->{stat} = [ split /\0/, $job->{stat} ];

   $job
}

sub slave {
   my ($self) = @_;

   for (;;) {
      my $job = $self->_recv ($self->{s})
         or last;

      $job->{slave} = $self;

      my $type = $type{$job->{type}}
         or die;

      eval {
         $type->{cb}->($job);
      };

      if ($@) {
         $job->{exception} = $@;
         $job->finish;
      }
   }
}

sub reply {
   my ($self) = @_;

   my $job = $self->_recv ($self->{m})
      or return;

   $job->finish;

   push @idle_slave, $self;
}

sub send {
   my ($self, $job) = @_;

   $self->_send ($self->{m}, $job);
}

sub event {
   my ($self, $event) = @_;

   $event->{event} = 1;

   $self->_send ($self->{s}, $event);
}

sub finish {
   my ($self, $job) = @_;

   $self->_send ($self->{s}, $job);
}

sub destroy {
   my ($self) = @_;

   remove Glib::Source delete $self->{w} if $self->{w};
}

=back

=head1 AUTHOR

Marc Lehmann <schmorp@schmorp.de>

=cut

1

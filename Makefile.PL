require 5.008;

use ExtUtils::MakeMaker;
use ExtUtils::Depends;

my $pkg = ExtUtils::Depends->new ("Gtk2::CV", "Gtk2", "Glib");

sub MY::postamble {
   my $self=shift;
   <<EOF

.PHONY: doc

run: all
	\$(PERL) -Mblib -MCarp=verbose bin/cv

EOF
}

WriteMakefile(
    dist	=> {
	            PREOP	=> 'pod2text bin/cv | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
	            COMPRESS	=> 'gzip -9v',
	            SUFFIX	=> '.gz',
	           },
    PREREQ_PM	=> {
    		    Glib		=> 1.01,
    		    Gtk2		=> 1.01,
                    Gtk2::PodViewer	=> 0.03,
                    Gtk2::GladeXML      => 0.93,
		   },
    DIR		=> [],
    NAME	=> 'Gtk2::CV',
    VERSION_FROM => 'lib/Gtk2/CV.pm',
    EXE_FILES	=> [qw(bin/cv)],
    $pkg->get_makefile_vars,
    PM		=> {
       'lib/Gtk2/CV/ImageWindow.pm'	=> '$(INST_LIBDIR)/CV/ImageWindow.pm',
       'lib/Gtk2/CV/Schnauzer.pm'	=> '$(INST_LIBDIR)/CV/Schnauzer.pm',
       'lib/Gtk2/CV/PostScript.pm'	=> '$(INST_LIBDIR)/CV/PostScript.pm',
       'lib/Gtk2/CV/PrintDialog.pm'	=> '$(INST_LIBDIR)/CV/PrintDialog.pm',
       'lib/Gtk2/CV.pm'			=> '$(INST_LIBDIR)/CV.pm',

       'gtkrc'				=> '$(INST_LIBDIR)/CV/gtkrc',
       'cv.glade'			=> '$(INST_LIBDIR)/CV/cv.glade',

       'images/cv.png'			=> '$(INST_LIBDIR)/CV/images/cv.png',
       'images/dir.png'			=> '$(INST_LIBDIR)/CV/images/dir.png',
       'images/file.png'		=> '$(INST_LIBDIR)/CV/images/file.png',
    },
);




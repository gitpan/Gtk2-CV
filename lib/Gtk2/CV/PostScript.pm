package Gtk2::CV::PostScript;

my $top = <<EOF;
%!PS-Adobe-3.0

gsave
20 dict begin

% slightly modified from gnu ghostscript
% dog-slow, actually, and not very effective
/ci
   {                                   % w h bit [] filter multi ncomp
     9 dict begin                      % w h bit [] filter multi ncomp
     7 copy
     gsave                             % preserve the arguments
     { 0 /DeviceGray 0 /DeviceRGB /DeviceCMYK }
     1 index get setcolorspace         % ... glob w h bit [] filter multi ncomp
     {0 1 0 1 0 1 0 1}
     1 index 2 mul 0 exch              % ... glob w h bit [] filter multi ncomp {0 1 ...} 0 2*ncomp
     getinterval /Decode exch def      % ... glob w h bit [] filter multi ncomp
     exch dup                          % ... glob w h bit [] filter ncomp multi multi
     /MultipleDataSources exch def     % ... glob w h bit [] filter ncomp multi
     { array astore} { pop } ifelse    % ... glob w h bit [] [filter]
     /DataSource exch def              % ... glob w h bit []
     /ImageMatrix exch def             % ... glob w h bit
     /BitsPerComponent exch def        % ... glob w h
     /Height exch def                  % ... glob w
     /Width exch def                   % ... glob 
     /ImageType 1 def
     /Interpolate //true def
     currentdict end        % ... <<>>
     image
     grestore
     exch { 4 add } { 6 } ifelse
     { pop } repeat                    % -
   } bind def

newpath clippath pathbbox
/y2 exch def
/x2 exch def
/y exch def
/x exch def

/w x2 x sub def
/h y2 y sub def

EOF

my $bot = <<EOF;

showpage
end

grestore

EOF

sub print_pb {
   my ($fh, $pb, %arg) = @_;

   print $fh $top;

   my ($w, $h) = ($pb->get_width, $pb->get_height);

   $a = $arg{aspect} || $w / $h;

   print $fh <<EOF;

/a $a def

a 1 gt w h div 1 gt eq
   {
     x y translate

     /W w def
     /H h def
   }
   {
     x2 y translate

     /W h def
     /H w def
     90 rotate
   }
ifelse

a W H div gt
  {
    W
    W a div
  }
  {
    H a mul
    H
  }
ifelse

2 copy
exch W sub neg 2 div
exch H sub neg 2 div translate
scale
    
$w $h 8
[ $w 0 0 -$h 0 $h ]
currentfile /ASCII85Decode filter
false 3 colorimage
   
EOF

   dump_pb $fh, $pb;
   print $fh $bot;
}

1;

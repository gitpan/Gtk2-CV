#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <gdk-pixbuf/gdk-pixbuf.h>

#include <gperl.h>
#include <gtk2perl.h>

#define IW 80

#define RAND (seed = (seed + 7141) * 54773 % 134456)

#define ELLIPSIS "\xe2\x80\xa6"

static guint32 a85_val;
static guint a85_cnt;
static guchar a85_buf[80], *a85_ptr;

static void
a85_init (void)
{
  a85_cnt = 4;
  a85_ptr = a85_buf;
}

static void
a85_push (PerlIO *fp, guchar c)
{
  a85_val = a85_val << 8 | c;

  if (!--a85_cnt)
    {
      a85_cnt = 4;
      if (a85_val)
        {
          a85_ptr[4] = (a85_val % 85) + 33; a85_val /= 85; 
          a85_ptr[3] = (a85_val % 85) + 33; a85_val /= 85; 
          a85_ptr[2] = (a85_val % 85) + 33; a85_val /= 85; 
          a85_ptr[1] = (a85_val % 85) + 33; a85_val /= 85;
          a85_ptr[0] = (a85_val     ) + 33;

          a85_ptr += 5;
        }
      else
        *a85_ptr++ = 'z';

      if (a85_ptr >= a85_buf + sizeof (a85_buf) - 7)
        {
          *a85_ptr++ = '\n';
          PerlIO_write (fp, a85_buf, a85_ptr - a85_buf);
          a85_ptr = a85_buf;
        }
    }
    
}

a85_finish (PerlIO *fp)
{
  while (a85_cnt != 4)
    a85_push (fp, 0);

  *a85_ptr++ = '~'; // probably buggy end-marker
  *a85_ptr++ = '>'; // probably buggy end-marker
  *a85_ptr++ = '\n';

  PerlIO_write (fp, a85_buf, a85_ptr - a85_buf);
}

/////////////////////////////////////////////////////////////////////////////

MODULE = Gtk2::CV PACKAGE = Gtk2::CV::ImageWindow

PROTOTYPES: ENABLE

GdkPixbuf_noinc *
transpose (GdkPixbuf *pb)
	CODE:
{
	int w = gdk_pixbuf_get_width (pb);
        int h = gdk_pixbuf_get_height (pb);
        int bpp = gdk_pixbuf_get_has_alpha (pb) ? 4 : 3;
        int x, y, i;
        guchar *src = gdk_pixbuf_get_pixels (pb), *dst;
        int sstr = gdk_pixbuf_get_rowstride (pb), dstr;

	RETVAL = gdk_pixbuf_new (GDK_COLORSPACE_RGB, bpp == 4, 8, h, w);

        dst = gdk_pixbuf_get_pixels (RETVAL);
        dstr = gdk_pixbuf_get_rowstride (RETVAL);

        for (y = 0; y < h; y++)
          for (x = 0; x < w; x++)
            for (i = 0; i < bpp; i++)
              dst[y * bpp + x * dstr + i] = src[x * bpp + y * sstr + i];
}
	OUTPUT:
        RETVAL

GdkPixbuf_noinc *
flop (GdkPixbuf *pb)
	CODE:
{
	int w = gdk_pixbuf_get_width (pb);
        int h = gdk_pixbuf_get_height (pb);
        int bpp = gdk_pixbuf_get_has_alpha (pb) ? 4 : 3;
        int x, y, i;
        guchar *src = gdk_pixbuf_get_pixels (pb), *dst;
        int sstr = gdk_pixbuf_get_rowstride (pb), dstr;

	RETVAL = gdk_pixbuf_new (GDK_COLORSPACE_RGB, bpp == 4, 8, w, h);

        dst = gdk_pixbuf_get_pixels (RETVAL);
        dstr = gdk_pixbuf_get_rowstride (RETVAL);

        for (y = 0; y < h; y++)
          for (x = 0; x < w; x++)
            for (i = 0; i < bpp; i++)
              dst[(w - 1 - x) * bpp + y * dstr + i] = src[x * bpp + y * sstr + i];
}
	OUTPUT:
        RETVAL

#############################################################################

MODULE = Gtk2::CV PACKAGE = Gtk2::CV::Schnauzer

GdkPixbuf_noinc *
p7_to_pb (int w, int h, guchar *src)
	CODE:
{
	int x, y;
        guchar *dst, *d;
        int dstr;

	RETVAL = gdk_pixbuf_new (GDK_COLORSPACE_RGB, 0, 8,  w, h);
        dst = gdk_pixbuf_get_pixels (RETVAL);
        dstr = gdk_pixbuf_get_rowstride (RETVAL);

        for (y = 0; y < h; y++)
          for (d = dst + y * dstr, x = 0; x < w; x++)
            {
              *d++ = (((*src >> 5) & 7) * 255 + 4) / 7;
              *d++ = (((*src >> 2) & 7) * 255 + 4) / 7;
              *d++ = (((*src >> 0) & 3) * 255 + 2) / 3;

              src++;
            }
}
	OUTPUT:
        RETVAL

SV *
pb_to_p7 (GdkPixbuf *pb)
	CODE:
{
	int w = gdk_pixbuf_get_width  (pb);
	int h = gdk_pixbuf_get_height (pb);
	int x, y;
        guchar *dst;
        int bpp = gdk_pixbuf_get_has_alpha (pb) ? 4 : 3;
        guchar *src = gdk_pixbuf_get_pixels (pb);
        int sstr = gdk_pixbuf_get_rowstride (pb);
        int Er[IW], Eg[IW], Eb[IW];
        int seed = 77;

	RETVAL = newSV (w * h);
        SvPOK_only (RETVAL);
        SvCUR_set (RETVAL, w * h);

        dst = SvPVX (RETVAL);

        memset (Er, 0, sizeof (int) * IW);
        memset (Eg, 0, sizeof (int) * IW);
        memset (Eb, 0, sizeof (int) * IW);

        /* some primitive error distribution + random dithering */

        for (y = 0; y < h; y++)
          {
            int er = 0, eg = 0, eb = 0;

            for (x = 0; x < w; x++)
              {
                int r, g, b;
                guchar *p = src + x * bpp + y * sstr;

                r = ((p[0] + er + Er[x]) * 7 + 128) / 255;
                g = ((p[1] + eg + Eg[x]) * 7 + 128) / 255;
                b = ((p[2] + eb + Eb[x]) * 3 + 128) / 255;

                r = r > 7 ? 7 : r < 0 ? 0 : r;
                g = g > 7 ? 7 : g < 0 ? 0 : g;
                b = b > 3 ? 3 : b < 0 ? 0 : b;

                er += p[0] - (r * 255 + 4) / 7;
                eg += p[1] - (g * 255 + 4) / 7;
                eb += p[2] - (b * 255 + 2) / 3;

                Er[x] = er / 2; er -= er / 2 + RAND % 7 - 3;
                Eg[x] = eg / 2; eg -= eg / 2 + RAND % 7 - 3;
                Eb[x] = eb / 2; eb -= eb / 2 + RAND % 7 - 3;

                *dst++ = r << 5 | g << 2 | b;
              }
          }
}
	OUTPUT:
        RETVAL

#############################################################################

MODULE = Gtk2::CV PACKAGE = Gtk2::CV::PostScript

void
dump_pb (PerlIO *fp, GdkPixbuf *pb)
	CODE:
{
	int w = gdk_pixbuf_get_width  (pb);
	int h = gdk_pixbuf_get_height (pb);
	int x, y, i;
        guchar *dst;
        int bpp = gdk_pixbuf_get_has_alpha (pb) ? 4 : 3;
        guchar *src = gdk_pixbuf_get_pixels (pb);
        int sstr = gdk_pixbuf_get_rowstride (pb);

        a85_init ();

        for (y = 0; y < h; y++)
          for (x = 0; x < w; x++)
            for (i = 0; i < 3; i++)
              a85_push (fp, src [x * bpp + y * sstr + i]);

        a85_finish (fp);
}





#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <gdk-pixbuf/gdk-pixbuf.h>

#include <gperl.h>
#include <gtk2perl.h>

#define IW 80

#define RAND (seed = (seed + 7141) * 54773 % 134456)

#define LINELENGTH 240

#define ELLIPSIS "\xe2\x80\xa6"

static guint32 a85_val;
static guint a85_cnt;
static guchar a85_buf[LINELENGTH], *a85_ptr;

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

static void
a85_finish (PerlIO *fp)
{
  while (a85_cnt != 4)
    a85_push (fp, 0);

  *a85_ptr++ = '~'; // probably buggy end-marker
  *a85_ptr++ = '>'; // probably buggy end-marker
  *a85_ptr++ = '\n';

  PerlIO_write (fp, a85_buf, a85_ptr - a85_buf);
}

static void
rgb_to_hsv (unsigned int  r, unsigned int  g, unsigned int  b,
            unsigned int *h, unsigned int *s, unsigned int *v)
{
  unsigned int mx = r; if (g > mx) mx = g; if (b > mx) mx = b;
  unsigned int mn = r; if (g < mn) mn = g; if (b < mn) mn = b;
  unsigned int delta = mx - mn;

  *v = mx;

  *s = mx ? delta * 255 / mx : 0;

  if (delta == 0)
    *h = 0;
  else
    {
      if (r == mx)
        *h = ((int)g - (int)b) * 255 / (int)(delta * 3);
      else if (g == mx)
        *h = ((int)b - (int)r) * 255 / (int)(delta * 3) + 52;
      else if (b == mx)
        *h = ((int)r - (int)g) * 255 / (int)(delta * 3) + 103;

      *h &= 255;
    }
}

/////////////////////////////////////////////////////////////////////////////

MODULE = Gtk2::CV PACKAGE = Gtk2::CV

PROTOTYPES: ENABLE

GdkPixbuf_noinc *
transpose (GdkPixbuf *pb)
	CODE:
{
	int w = gdk_pixbuf_get_width (pb);
        int h = gdk_pixbuf_get_height (pb);
        int bpp = gdk_pixbuf_get_n_channels (pb);
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
        int bpp = gdk_pixbuf_get_n_channels (pb);
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
        int bpp = gdk_pixbuf_get_n_channels (pb);
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
dump_ascii85 (PerlIO *fp, GdkPixbuf *pb)
	CODE:
{
	int w = gdk_pixbuf_get_width  (pb);
	int h = gdk_pixbuf_get_height (pb);
	int x, y, i;
        guchar *dst;
        int bpp = gdk_pixbuf_get_n_channels (pb);
        guchar *src = gdk_pixbuf_get_pixels (pb);
        int sstr = gdk_pixbuf_get_rowstride (pb);

        a85_init ();

        for (y = 0; y < h; y++)
          for (x = 0; x < w; x++)
            for (i = 0; i < (bpp < 3 ? 1 : 3); i++)
              a85_push (fp, src [x * bpp + y * sstr + i]);

        a85_finish (fp);
}

void
dump_binary (PerlIO *fp, GdkPixbuf *pb)
	CODE:
{
	int w = gdk_pixbuf_get_width  (pb);
	int h = gdk_pixbuf_get_height (pb);
	int x, y, i;
        guchar *dst;
        int bpp = gdk_pixbuf_get_n_channels (pb);
        guchar *src = gdk_pixbuf_get_pixels (pb);
        int sstr = gdk_pixbuf_get_rowstride (pb);

        for (y = 0; y < h; y++)
          for (x = 0; x < w; x++)
            for (i = 0; i < (bpp < 3 ? 1 : 3); i++)
              PerlIO_putc (fp, src [x * bpp + y * sstr + i]);
}

#############################################################################

MODULE = Gtk2::CV PACKAGE = Gtk2::CV

SV *
pb_to_hv84 (GdkPixbuf *pb)
	CODE:
{
	int w = gdk_pixbuf_get_width  (pb);
	int h = gdk_pixbuf_get_height (pb);
	int x, y;
        guchar *dst;
        int bpp = gdk_pixbuf_get_n_channels (pb);
        guchar *src = gdk_pixbuf_get_pixels (pb);
        int sstr = gdk_pixbuf_get_rowstride (pb);

	RETVAL = newSV (6 * 8 * 12 / 8);
        SvPOK_only (RETVAL);
        SvCUR_set (RETVAL, 6 * 8 * 12 / 8);

        dst = SvPVX (RETVAL);

        /* some primitive error distribution + random dithering */

        for (y = 0; y < h; y++)
          {
            guchar *p = src + y * sstr;

            for (x = 0; x < w; x += 2)
              {
                unsigned int r, g, b, h, s, v, H, V1, V2;

                if (bpp == 3)
                  r = *p++, g = *p++, b = *p++;
                else if (bpp == 1)
                  r = g = b = *p++;
                else
                  abort ();

                rgb_to_hsv (r, g, b, &h, &s, &v);

                H = (h * 15 / 255) << 4;
                V1 = v;

                if (bpp == 3)
                  r = *p++, g = *p++, b = *p++;
                else if (bpp == 1)
                  r = g = b = *p++;
                else
                  abort ();

                rgb_to_hsv (r, g, b, &h, &s, &v);

                H |= h * 15 / 255;
                V2 = v;

                *dst++ = H;
                *dst++ = V1;
                *dst++ = V2;
              }
          }
}
	OUTPUT:
        RETVAL

SV *
hv84_to_av (unsigned char *hv84)
	CODE:
{
        int i = 72 / 3;
        AV *av = newAV ();

        RETVAL = (SV *)newRV_noinc ((SV *)av);
        while (i--)
          {
            int h  = *hv84++;
            int v1 = *hv84++;
            int v2 = *hv84++;

            av_push (av, newSViv (v1));
            av_push (av, newSViv ((h >> 4) * 255 / 15));
            av_push (av, newSViv (v2));
            av_push (av, newSViv ((h & 15) * 255 / 15));
          }
}
	OUTPUT:
        RETVAL




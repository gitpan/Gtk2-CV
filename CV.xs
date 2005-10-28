#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <string.h>
#include <setjmp.h>

#include <jpeglib.h>
#include <glib.h>
#include <gtk/gtk.h>
#include <gdk-pixbuf/gdk-pixbuf.h>

#include <gperl.h>
#include <gtk2perl.h>

#define IW 80 /* MUST match Schnauer.pm! */
#define IH 60 /* MUST match Schnauer.pm! */

#define RAND (seed = (seed + 7141) * 54773 % 134456)

#define LINELENGTH 240

#define ELLIPSIS "\xe2\x80\xa6"

struct jpg_err_mgr
{
  struct jpeg_error_mgr err;
  jmp_buf setjmp_buffer;
};

static void
cv_error_exit (j_common_ptr cinfo)
{
  longjmp (((struct jpg_err_mgr *)cinfo->err)->setjmp_buffer, 99);
}

static void
cv_error_output (j_common_ptr cinfo)
{
  return;
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

/////////////////////////////////////////////////////////////////////////////

MODULE = Gtk2::CV PACKAGE = Gtk2::CV

PROTOTYPES: ENABLE

# missing function in perl. really :)
int
common_prefix_length (a, b)
	unsigned char *a = (unsigned char *)SvPVutf8_nolen ($arg);
	unsigned char *b = (unsigned char *)SvPVutf8_nolen ($arg);
	CODE:
        RETVAL = 0;

        while (*a == *b && *a)
          {
            RETVAL += (*a & 0xc0) != 0x80;
            a++, b++;
          }

        OUTPUT:
        RETVAL

# missing in Gtk2 perl module

gboolean
gdk_net_wm_supports (GdkAtom property)
	CODE:
#if defined(GDK_WINDOWING_X11) && !defined(GDK_MULTIHEAD_SAFE)
        RETVAL = gdk_net_wm_supports (property);
#else
        RETVAL = 0;
#endif
        OUTPUT:
        RETVAL

GdkPixbuf_noinc *
dealpha_expose (GdkPixbuf *pb)
	CODE:
{
	int w = gdk_pixbuf_get_width (pb);
        int h = gdk_pixbuf_get_height (pb);
        int bpp = gdk_pixbuf_get_n_channels (pb);
        int x, y, i;
        guchar *src = gdk_pixbuf_get_pixels (pb), *dst;
        int sstr = gdk_pixbuf_get_rowstride (pb), dstr;

	RETVAL = gdk_pixbuf_new (GDK_COLORSPACE_RGB, 0, 8, w, h);

        dst = gdk_pixbuf_get_pixels (RETVAL);
        dstr = gdk_pixbuf_get_rowstride (RETVAL);

        for (x = 0; x < w; x++)
          for (y = 0; y < h; y++)
            for (i = 0; i < 3; i++)
              dst[x * 3 + y * dstr + i] = src[x * bpp + y * sstr + i];
}
	OUTPUT:
        RETVAL

GdkPixbuf_noinc *
rotate (GdkPixbuf *pb, int angle)
	CODE:
        RETVAL = gdk_pixbuf_rotate_simple (pb, angle ==   0 ? GDK_PIXBUF_ROTATE_NONE
                                             : angle ==  90 ? GDK_PIXBUF_ROTATE_COUNTERCLOCKWISE
                                             : angle == 180 ? GDK_PIXBUF_ROTATE_UPSIDEDOWN
                                             : angle == 270 ? GDK_PIXBUF_ROTATE_CLOCKWISE
                                             : angle);
	OUTPUT:
        RETVAL

GdkPixbuf_noinc *
load_jpeg (SV *path, int thumbnail=0)
	CODE:
{
        struct jpeg_decompress_struct cinfo;
        struct jpg_err_mgr jerr;
        guchar *data;
        int rs;
        FILE *fp;
        volatile GdkPixbuf *pb = 0;
        gchar *filename;

        RETVAL = 0;

        filename = g_filename_from_utf8 (SvPVutf8_nolen (path), -1, 0, 0, 0);
        fp = fopen (filename, "rb");
        g_free (filename);

        if (!fp)
          XSRETURN_UNDEF;

        cinfo.err = jpeg_std_error (&jerr.err);

        jerr.err.error_exit     = cv_error_exit;
        jerr.err.output_message = cv_error_output;

        if ((rs = setjmp (jerr.setjmp_buffer)))
          {
            fclose (fp);
            jpeg_destroy_decompress (&cinfo);

            if (pb)
              g_object_unref ((gpointer)pb);

            XSRETURN_UNDEF;
          }

        jpeg_create_decompress (&cinfo);

        jpeg_stdio_src (&cinfo, fp);
        jpeg_read_header (&cinfo, TRUE);

        cinfo.dct_method          = JDCT_DEFAULT;
        cinfo.do_fancy_upsampling = FALSE; /* worse quality, but nobody compained so far, and gdk-pixbuf does the same */
        cinfo.do_block_smoothing  = FALSE;
        cinfo.out_color_space     = JCS_RGB;
        cinfo.quantize_colors     = FALSE;

        cinfo.scale_num   = 1;
        cinfo.scale_denom = 1;

        jpeg_calc_output_dimensions (&cinfo);

        if (thumbnail)
          {
            cinfo.dct_method          = JDCT_FASTEST;
            cinfo.do_fancy_upsampling = FALSE;

            while (cinfo.scale_denom < 8
                   && cinfo.output_width  >= IW*4
                   && cinfo.output_height >= IH*4)
              {
                cinfo.scale_denom <<= 1;
                jpeg_calc_output_dimensions (&cinfo);
              }
          }

	pb = RETVAL = gdk_pixbuf_new (GDK_COLORSPACE_RGB, 0, 8,  cinfo.output_width, cinfo.output_height);
        if (!RETVAL)
          longjmp (jerr.setjmp_buffer, 2);

        data = gdk_pixbuf_get_pixels (RETVAL);
        rs = gdk_pixbuf_get_rowstride (RETVAL);

        if (cinfo.output_components != 3)
          longjmp (jerr.setjmp_buffer, 3);

        jpeg_start_decompress (&cinfo);

        while (cinfo.output_scanline < cinfo.output_height)
          {
            int remaining = cinfo.output_height - cinfo.output_scanline;
            JSAMPROW rp[4];

            rp [0] = data + cinfo.output_scanline * rs;
            rp [1] = (guchar *)rp [0] + rs;
            rp [2] = (guchar *)rp [1] + rs;
            rp [3] = (guchar *)rp [2] + rs;

            jpeg_read_scanlines (&cinfo, rp, remaining < 4 ? remaining : 4);
          }

        jpeg_finish_decompress (&cinfo);
        fclose (fp);
        jpeg_destroy_decompress (&cinfo);
}
	OUTPUT:
        RETVAL

#############################################################################

MODULE = Gtk2::CV PACKAGE = Gtk2::CV::Schnauzer

SV *
foldcase (SV *pathsv)
	PROTOTYPE: $
	CODE:
{
	STRLEN plen;
        U8 *path = (U8 *)SvPVutf8 (pathsv, plen);
        U8 *pend = path + plen;
        U8 dst [plen * 6 * 3], *dstp = dst;

        while (path < pend)
          {
            U8 ch = *path;

            if (ch >= 'a' && ch <= 'z')
              *dstp++ = *path++;
            else if (ch >= '0' && ch <= '9')
              {
                STRLEN el, nl = 0;
                while (*path >= '0' && *path <= '9' && path < pend)
                  path++, nl++;

                for (el = nl; el < 6; el++)
                  *dstp++ = '0';

                memcpy (dstp, path - nl, nl);
                dstp += nl;
              }
            else
              {
                STRLEN cl;
                to_utf8_fold (path, dstp, &cl);
                dstp += cl;
                path += is_utf8_char (path);
              }
          }

        RETVAL = newSVpvn ((const char *)dst, dstp - dst);
}
	OUTPUT:
        RETVAL

GdkPixbuf_noinc *
p7_to_pb (int w, int h, SV *src_sv)
        PROTOTYPE: @
	CODE:
{
	int x, y;
        guchar *dst, *d;
        int dstr;
        guchar *src = (guchar *)SvPVbyte_nolen (src_sv);

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

        dst = (guchar *)SvPVX (RETVAL);

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

#############################################################################

MODULE = Gtk2::CV PACKAGE = Gtk2::CV::Plugin::RCluster

SV *
make_histograms (SV *ar)
        CODE:
{
        int i;
        AV *av, *result;

        if (!SvROK (ar) || SvTYPE (SvRV (ar)) != SVt_PVAV)
          croak ("Not an array ref as first argument to make_histogram");

        av = (AV *) SvRV (ar);
        result = newAV ();

        for (i = 0; i <= av_len (av); ++i)
          {
            const int HISTSIZE = 64;

            int j;
            SV *sv = *av_fetch (av, i, 1);
            STRLEN len;
            char *buf = SvPVbyte (sv, len);

            int tmphist[HISTSIZE];
            float *hist;

            SV *histsv = newSV (HISTSIZE * sizeof (float) + 1);
            SvPOK_on (histsv);
            SvCUR_set (histsv, HISTSIZE * sizeof (float));
            hist = (float *)SvPVX (histsv);

            Zero (tmphist, sizeof (tmphist), char);

            for (j = len; j--; )
              {
                unsigned int idx
                    = ((*buf & 0xc0) >> 2)
                    | ((*buf & 0x18) >> 1)
                    |  (*buf & 0x03);

                ++tmphist[idx];
                ++buf;
              }
            
            for (j = 0; j < HISTSIZE; ++j)
              hist[j] = (float)tmphist[j] / (len + 1e-30);

            av_push (result, histsv);
          }

        RETVAL = newRV_noinc ((SV *)result);
}
        OUTPUT:
        RETVAL



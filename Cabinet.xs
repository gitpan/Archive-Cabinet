/*
 * Filename: Cabinet.xs
 * Author  : Brad Douglas, <rez@touchofmadness.com>
 * Created : 10 April 2005
 * Version : 1.00
 *
 *   Copyright (c) 2005 Brad Douglas. All rights reserved.
 *   This program is free software; you can redistribute it and/or
 *   modify it under the same terms as Perl itself.
 *
 *
 * Partially plundered from libmspack out of sheer laziness.
 *
 */

#define _GNU_SOURCE 1

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <utime.h>

#include <sys/types.h>
#include <sys/stat.h>

#include "mspack.h"


/***** PROTOTYPES *****/

typedef struct mscab_decompressor *Archive__Cabinet__decomp;
typedef struct mscabd_cabinet     *Archive__Cabinet__cab;
typedef struct mscabd_folder      *Archive__Cabinet__folder;
typedef struct mscabd_file        *Archive__Cabinet__file;

typedef struct cabType {
    Archive__Cabinet__decomp cabd;
    Archive__Cabinet__cab cab;
    int isunix;
    bool closed;
} cabType;
typedef struct cabType *Archive__Cabinet__cabFile;

/* Internal functions */
static void SetCabError(struct cabType *f);
static int arch_size(void);
static int unix_path_seperators(struct mscabd_file *f);
static char *create_output_name(unsigned char *fname, int isunix, int utf8);
static int ensure_filepath(char *pth);


/***** GLOBAL DATA *****/

#define CABERRNO    "Archive::Cabinet::caberrno"

#define STREQ(a, b)         (strcmp(a, b) == 0)
#define ZMALLOC(to, typ)    ((to = (typ *)safemalloc(sizeof(typ))), Zero(to,1,typ))

/* Error strings */
static char *my_cab_errmsg[] = {
    "",                           /* ERR_OK         (0) */
    "bad argument(s)",            /* ERR_ARGS       (1) */
    "open file error",            /* ERR_OPEN       (2) */
    "read file error",            /* ERR_READ       (3) */
    "write file error",           /* ERR_WRITE      (4) */
    "file seek error",            /* ERR_SEEK       (5) */
    "insufficient memory",        /* ERR_NOMEMORY   (6) */
    "invalid file signature",     /* ERR_SIGNATURE  (7) */
    "bad or corrupt file format", /* ERR_DATAFORMAT (8) */
    "bad checksum",               /* ERR_CHECKSUM   (9) */
    "compression error",          /* ERR_CRUNCH    (10) */
    "decompression error",        /* ERR_DECRUNCH  (11) */
    ""
};


/* Internal Functions */
static void
SetCabError(struct cabType *f)
{
    Archive__Cabinet__decomp cabd = f->cabd;
    SV *caberror_sv = perl_get_sv(CABERRNO, FALSE);
    int error_no;

    error_no = cabd->last_error(cabd);

    if (SvIV(caberror_sv) != error_no) {
        sv_setiv(caberror_sv, error_no);
        sv_setpv(caberror_sv, my_cab_errmsg[error_no]);
        SvIOK_on(caberror_sv);
    }
}


static int
arch_size(void)
{
    return (sizeof(off_t) == 4) ? 64 : 32;
}


static int unix_path_seperators(struct mscabd_file *f)
{
    struct mscabd_file *fi;
    char slash = 0;
    char backslash = 0;
    char *oldname;
    int oldlen;

    for (fi = f; fi; fi = fi->next) {
        char *p;

        for (p = fi->filename; *p; p++) {
            if (*p == '/')  slash     = 1;
            if (*p == '\\') backslash = 1;
        }

        if (slash && backslash)
            break;
    }

    if (slash) {
        /* slashes, but no backslashes = UNIX */
        if (!backslash)
            return 1;
    } else {
        /* no slashes = MS-DOS */
        return 0;
    }

    /* special case if there's only one file - just take the first slash */
    if (!f->next) {
        char c, *p = fi->filename;

        while ((c = *p++)) {
            if (c == '\\') return 0; /* backslash = MS-DOS */
            if (c == '/')  return 1; /* slash = UNIX */
        }

        /* should not happen - at least one slash was found! */
        return 0;
    }

    oldname = NULL;
    oldlen = 0;
    for (fi = f; fi; fi = fi->next) {
        char *name = fi->filename;
        int len = 0;

        while (name[len]) {
            if ((name[len] == '\\') || (name[len] == '/'))
                break;

            len++;
        }

        len = (!name[len]) ? 0 : len + 1;

        if (len && (len == oldlen))
            if (strncmp(name, oldname, (size_t)len) == 0)
                return (name[len-1] == '\\') ? 0 : 1;

        oldname = name;
        oldlen = len;
    }

    /* default */
    return 0;
}


static char *create_output_name(unsigned char *fname, int isunix, int utf8)
{
    unsigned char *p, *name, c, *fe, sep, slash;
    unsigned int x;

    sep   = (isunix) ? '/'  : '\\'; /* the path-seperator */
    slash = (isunix) ? '\\' : '/';  /* the other slash */

    /* length of filename */
    x = strlen((char *)fname);

    /* UTF8 worst case scenario: tolower() expands all chars from 1 to 3 bytes */
    if (utf8) x *= 3;

    if (!(name = malloc(x + 2))) {
        fprintf(stderr, "Can't allocate output filename (%u bytes)\n", x + 2);

        return NULL;
    }
  
    /* start with blank name */
    *name = '\0';

    /* remove leading slashes */
    while (*fname == sep)
        fname++;

    /* copy from fi->filename to new name, converting MS-DOS slashes to UNIX
     * slashes as we go. Also lowercases characters if needed. */
    p  = &name[strlen((char *)name)];
    fe = &fname[strlen((char *)fname)];

    if (utf8) {
        /* UTF8 translates two-byte unicode characters into 1, 2 or 3 bytes.
         * %000000000xxxxxxx -> %0xxxxxxx
         * %00000xxxxxyyyyyy -> %110xxxxx %10yyyyyy
         * %xxxxyyyyyyzzzzzz -> %1110xxxx %10yyyyyy %10zzzzzz
         *
         * Therefore, the inverse is as follows:
         * First char:
         *  0x00 - 0x7F = one byte char
         *  0x80 - 0xBF = invalid
         *  0xC0 - 0xDF = 2 byte char (next char only 0x80-0xBF is valid)
         *  0xE0 - 0xEF = 3 byte char (next 2 chars only 0x80-0xBF is valid)
         *  0xF0 - 0xFF = invalid */
        do {
            if (fname >= fe) {
                fprintf(stderr, "error in UTF-8 decode\n");
                free(name);

                return NULL;	
            }

            /* get next UTF8 char */
            if ((c = *fname++) < 0x80)
                x = c;
            else {
                if ((c >= 0xC0) && (c < 0xE0)) {
                    x  = (c & 0x1F) << 6;
                    x |= *fname++ & 0x3F;
                } else if ((c >= 0xE0) && (c < 0xF0)) {
                    x  = (c & 0xF) << 12;
                    x |= (*fname++ & 0x3F) << 6;
                    x |= *fname++ & 0x3F;
                } else x = '?';
            }

            /* whatever is the path seperator -> '/'
             * whatever is the other slash    -> '\\'
             * otherwise, if lower is set, the lowercase version */
            if      (x == sep)   x = '/';
            else if (x == slash) x = '\\';

            /* integer back to UTF8 */
            if (x < 0x80) {
                *p++ = (unsigned char)x;
            } else if (x < 0x800) {
                *p++ = 0xC0 | (x >> 6);   
                *p++ = 0x80 | (x & 0x3F);
            } else {
                *p++ = 0xE0 | (x >> 12);
                *p++ = 0x80 | ((x >> 6) & 0x3F);
                *p++ = 0x80 | (x & 0x3F);
            }
        } while (x);
    } else {
        /* regular non-utf8 version */
        do {
            c = *fname++;

            if      (c == sep)   c = '/';
            else if (c == slash) c = '\\';
        } while ((*p++ = c));
    }

    /* search for "../" in cab filename part and change to "xx/".  This
     * prevents any unintended directory traversal. */
    for (p = &name[0]; *p; p++) {
        if ((p[0] == '.') && (p[1] == '.') && (p[2] == '/')) {
            p[0] = p[1] = 'x';
            p += 2;
        }
    }

    return (char *)name;
}


static int ensure_filepath(char *pth)
{
    struct stat st_buf;
    mode_t user_umask = umask(0);
    char *p;
    int ok;

    for (p = &pth[1]; *p; p++)
    {
        if (*p != '/')
            continue;

        *p = '\0';
        ok = (stat(pth, &st_buf) == 0) && S_ISDIR(st_buf.st_mode);

        if (!ok)
            ok = (mkdir(pth, 0777 & ~user_umask) == 0);
        *p = '/';

        if (!ok)
            return 0;
    }

    return 1;
}


/***** PerlXS Section *****/

MODULE = Archive::Cabinet	PACKAGE = Archive::Cabinet

PROTOTYPES: DISABLE

BOOT:
{
    int err;

    MSPACK_SYS_SELFTEST(err);
    if (err)
        croak("Archive::Cabinet is %d-bit and libmspack not %d-bit.\n",
                arch_size(), arch_size());

    {
        /* Create caberror scalar */
        SV *caberror_sv = perl_get_sv(CABERRNO, GV_ADDMULTI);
        sv_setiv(caberror_sv, 0);
        sv_setpv(caberror_sv, "");
        SvIOK_on(caberror_sv);
    }
}


Archive::Cabinet::cabFile
new(Class, char *filename=NULL)
    CODE:
    {
        Archive__Cabinet__cabFile f = NULL;

        /* If name specified, validate */
        if (filename) {
            struct stat buf;

            if (stat(filename, &buf))
                XSRETURN_UNDEF;
        }

        ZMALLOC(f, cabType);
        if (!f)
            XSRETURN_UNDEF;

        /* Start with closed file */
        f->closed = TRUE;
        f->cab = NULL;

        /* Initialize engine */
        if (f->cabd == NULL) {
            f->cabd = mspack_create_cab_decompressor(NULL);
            if (f->cabd == NULL) {
                safefree(f);
                XSRETURN_UNDEF;
            }
        }

        /* Open the cabinet if exists */
        if (filename) {
            Archive__Cabinet__decomp cabd = f->cabd;
            Archive__Cabinet__cab    cab  = NULL;

            cab = cabd->search(cabd, filename);
            if (cabd->last_error(cabd)) {
                SetCabError(f);
                safefree(f);
                XSRETURN_UNDEF;
            }

            f->cab = cab;
            f->closed = FALSE;
            f->isunix = unix_path_seperators(cab->files);
        }

        RETVAL = f;
    }
    OUTPUT:
        RETVAL


void
DESTROY(Archive::Cabinet::cabFile f)
    CODE:
    {
        Archive__Cabinet__decomp cabd = f->cabd;

        if (!f->closed)
            cabd->close(cabd, f->cab);

        mspack_destroy_cab_decompressor(cabd);
        safefree(f);
    }


MODULE = Archive::Cabinet	PACKAGE = Archive::Cabinet::cabFile	PREFIX = Cab_

Archive::Cabinet::cabFile
Cab_open(Archive::Cabinet::cabFile f, char *name)
    CODE:
    {
        Archive__Cabinet__decomp cabd = f->cabd;
        Archive__Cabinet__cab cab = NULL;

        if (!name)
            XSRETURN_UNDEF;

        /* Already open? */
        if (!f->closed) {
            warn("This archive has already been opened!\n");
            XSRETURN_UNDEF;
        }

        cab = cabd->search(cabd, name);
        f->cab = cab;
        f->closed = FALSE;
        f->isunix = unix_path_seperators(cab->files);

        RETVAL = f;
    }
    OUTPUT:
        RETVAL


AV *
Cab_list_files(Archive::Cabinet::cabFile f)
    INIT:
        AV *list;
        list = (AV *)sv_2mortal((SV *)newAV());
    CODE:
    {
        Archive__Cabinet__file file;

        /* Exit if not opened */
        if (f->closed)
            XSRETURN_EMPTY;

        for (file = f->cab->files; file; file = file->next) {
            char *name;

            name = create_output_name((unsigned char *)file->filename,
                f->isunix, file->attribs & MSCAB_ATTRIB_UTF_NAME);

            av_push(list, newSVpvn(name, strlen(name)));
            safefree(name);
        }

        RETVAL = list;
    }
    OUTPUT:
        RETVAL


SV *
Cab_extract(Archive::Cabinet::cabFile f, char *filename)
    CODE:
    {
        Archive__Cabinet__decomp cabd = f->cabd;
        Archive__Cabinet__file file = f->cab->files;

        int found = 0;

        /* Exit if not opened */
        if (f->closed)
            XSRETURN_UNDEF;

        /* Find the file we're looking for */
        for (file; file; file = file->next) {
            /* This can probably be done much easier, but I'm lazy (still) */
            if (STREQ(file->filename, filename)) {
                found = 1;
                char *tmpf = tempnam(NULL, NULL);
                struct stat stat;
                int fd;
                void *ptr;
                SV *buf;

                /* Extract to temp file */
                cabd->extract(cabd, file, tmpf);

                /* Get file size and allocate memory */
                fd = open(tmpf, O_RDONLY);
                fstat(fd, &stat);
                ptr = safemalloc(stat.st_size);

                read(fd, ptr, stat.st_size);
                close(fd);

                /* Make new scalar with contents of ptr */
                buf = newSVpv(ptr, strlen(ptr));
                safefree(ptr);
                safefree(tmpf);

                /* Remove the temp file */
                unlink(tmpf);

                RETVAL = buf;
            }
        }
        if ( !found )
          RETVAL = &PL_sv_undef;
    }
    OUTPUT:
        RETVAL

int
Cab_extract_to_file(Archive::Cabinet::cabFile f, char *filename, char *dest=NULL)
    CODE:
    {
        Archive__Cabinet__decomp cabd = f->cabd;
        Archive__Cabinet__file file = f->cab->files;

        /* Exit if not opened */
        if (f->closed || !filename)
            XSRETURN_IV(0);

        /* Find the file we're looking for */
        for (file; file; file = file->next) {
            if (STREQ(file->filename, filename)) {
                int err;

                /* Extract a single file to dest */
                cabd->extract(cabd, file, dest);
                err = cabd->last_error(cabd);
                if (err) {
                    SetCabError(f);
                    XSRETURN_IV(0);
                }

                break;
            }
        }

        RETVAL = 1;
    }
    OUTPUT:
        RETVAL


int
Cab_extract_all(Archive::Cabinet::cabFile f)
    CODE:
    {
        Archive__Cabinet__decomp cabd = f->cabd;
        Archive__Cabinet__file file = f->cab->files;

        if (f->closed)
            XSRETURN_IV(0);

        for (file; file; file = file->next) {
            int err;
            char *name;

            name = create_output_name((unsigned char *)file->filename,
                   f->isunix, file->attribs & MSCAB_ATTRIB_UTF_NAME);

            ensure_filepath(name);

            /* Extract all files */
            cabd->extract(cabd, file, name);

            if (err = cabd->last_error(cabd)) {
                SetCabError(f);
                XSRETURN_IV(err);
            }

            safefree(name);
        }

        RETVAL = 1;
    }
    OUTPUT:
        RETVAL


HV *
Cab_get_file_attributes(Archive::Cabinet::cabFile f)
    CODE:
    {
        Archive__Cabinet__decomp cabd = f->cabd;
        Archive__Cabinet__file file = f->cab->files;

        RETVAL = newHV();

        for (file; file; file = file->next) {
            HV* fattr = newHV();
            hv_store(fattr, "date", 4, newSVpvf("%02d-%02d-%02d",
                    file->date_m, file->date_d, file->date_y), 0);
            hv_store(fattr, "time", 4, newSVpvf("%02d:%02d:%02d",
                    file->time_h, file->time_m, file->time_s), 0);
            hv_store(fattr, "size", 4, newSVnv(file->length), 0);
            hv_store(RETVAL, file->filename, strlen(file->filename), 
                    newRV_inc((SV*)fattr), 0);
        }
    }
    OUTPUT:
        RETVAL


int
Cab_close(Archive::Cabinet::cabFile f)
    CODE:
    {
        Archive__Cabinet__decomp cabd = f->cabd;

        if (!f->closed) {
            cabd->close(cabd, f->cab);

            f->closed = TRUE;
            RETVAL = cabd->last_error(cabd);
            SetCabError(f);
        } else
            RETVAL = 0;
    }
    OUTPUT:
        RETVAL
        f

/*
 * libsup.c -- bare-metal support routines (memset/memcpy/memmove).
 * Standard freestanding support for the port; NOT part of the timed
 * benchmark code.
 */
#include <stddef.h>

void *memset(void *s, int c, size_t n)
{
    unsigned char *p = (unsigned char *)s;
    while (n--)
        *p++ = (unsigned char)c;
    return s;
}

void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char       *dp = (unsigned char *)d;
    const unsigned char *sp = (const unsigned char *)s;
    while (n--)
        *dp++ = *sp++;
    return d;
}

void *memmove(void *d, const void *s, size_t n)
{
    unsigned char       *dp = (unsigned char *)d;
    const unsigned char *sp = (const unsigned char *)s;
    if (dp < sp)
        while (n--)
            *dp++ = *sp++;
    else if (dp > sp)
    {
        dp += n;
        sp += n;
        while (n--)
            *--dp = *--sp;
    }
    return d;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *pa = (const unsigned char *)a;
    const unsigned char *pb = (const unsigned char *)b;
    while (n--)
    {
        if (*pa != *pb)
            return (int)*pa - (int)*pb;
        pa++;
        pb++;
    }
    return 0;
}

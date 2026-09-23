/*
 * ee_printf.c -- minimal integer-only printf for the bare-metal CoreMark port.
 *
 * Supports %d %u %x %X %s %c %% with optional 'l' length modifier.
 * Output goes to a static RAM log buffer; the benchmark's own validity
 * checks (known CRCs) print "ERROR" lines on mismatch, which the final
 * report scans for. Nothing is written to the tohost word here, so the
 * testbench protocol cannot be corrupted.
 */
#include <stdarg.h>
#include "core_portme.h"

#define LOG_SIZE 8192
char  ee_log_buf[LOG_SIZE];
ee_u32 ee_log_len = 0;
ee_u32 ee_error_seen = 0;

static void log_putc(char c)
{
    if (ee_log_len + 1 < LOG_SIZE)
        ee_log_buf[ee_log_len++] = c;
    ee_log_buf[ee_log_len] = '\0';
}

static void log_puts(const char *s)
{
    while (*s)
        log_putc(*s++);
}

static void log_putu(unsigned long v, unsigned base, int upper,
                    int width, int zero_pad)
{
    char tmp[32];
    int  n = 0;
    if (v == 0)
        tmp[n++] = '0';
    while (v > 0)
    {
        unsigned d = (unsigned)(v % base);
        tmp[n++] = (char)(d < 10 ? '0' + d : (upper ? 'A' : 'a') + d - 10);
        v /= base;
    }
    while (n < width)
        tmp[n++] = zero_pad ? '0' : ' ';
    while (n > 0)
        log_putc(tmp[--n]);
}

int ee_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    while (*fmt)
    {
        if (*fmt != '%')
        {
            log_putc(*fmt++);
            continue;
        }
        fmt++;
        int is_long = 0;
        int width = 0;
        int zero_pad = 0;
        if (*fmt == 'l')
        {
            is_long = 1;
            fmt++;
        }
        if (*fmt == '0')
        {
            zero_pad = 1;
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9')
        {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }
        switch (*fmt)
        {
        case 'd':
        {
            long v = is_long ? va_arg(ap, long) : va_arg(ap, int);
            if (v < 0)
            {
                log_putc('-');
                v = -v;
            }
            log_putu((unsigned long)v, 10, 0, width, zero_pad);
            break;
        }
        case 'u':
            log_putu(is_long ? va_arg(ap, unsigned long)
                             : va_arg(ap, unsigned int),
                     10, 0, width, zero_pad);
            break;
        case 'x':
            log_putu(is_long ? va_arg(ap, unsigned long)
                             : va_arg(ap, unsigned int),
                     16, 0, width, zero_pad);
            break;
        case 'X':
            log_putu(is_long ? va_arg(ap, unsigned long)
                             : va_arg(ap, unsigned int),
                     16, 1, width, zero_pad);
            break;
        case 's':
            log_puts(va_arg(ap, const char *));
            break;
        case 'c':
            log_putc((char)va_arg(ap, int));
            break;
        case '%':
            log_putc('%');
            break;
        default:
            log_putc('%');
            log_putc(*fmt);
            break;
        }
        fmt++;
    }
    va_end(ap);
    return 0;
}

/* Scan the log for the benchmark's own validity failures. */
ee_u32 ee_log_has_error(void)
{
    const char *p = ee_log_buf;
    while (*p)
    {
        if (p[0] == 'E' && p[1] == 'R' && p[2] == 'R' && p[3] == 'O'
            && p[4] == 'R')
            return 1;
        p++;
    }
    return 0;
}

/* CRC-specific: 1 if any "ERROR! ... crc ..." mismatch line is present.
 * (The generic "ERROR! Must execute for at least 10 secs" notice is a
 * reporting-validity rule, not a computation failure, so it is excluded.) */
ee_u32 ee_log_has_crc_error(void)
{
    const char *p = ee_log_buf;
    while (*p)
    {
        if (p[0] == 'E' && p[1] == 'R' && p[2] == 'R' && p[3] == 'O'
            && p[4] == 'R' && p[5] == '!')
        {
            const char *q = p + 6, *eol = q;
            while (*eol && *eol != '\n')
                eol++;
            while (q + 2 < eol)
            {
                if (q[0] == 'c' && q[1] == 'r' && q[2] == 'c')
                    return 1;
                q++;
            }
            p = eol;
        }
        else
            p++;
    }
    return 0;
}

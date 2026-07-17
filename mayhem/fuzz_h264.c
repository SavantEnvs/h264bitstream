/* In-process libFuzzer harness for h264bitstream.
 *
 * Drives the same code path as the h264_analyze CLI: scan the input for NAL
 * units with find_nal_unit() and parse each one with read_debug_nal_unit(),
 * exercising the SPS/PPS/SEI/slice-header readers in h264_stream.c /
 * h264_sei.c / h264_nal.c. Debug output is redirected away from stdout so the
 * fuzzer is not throttled by printing.
 */
#define _GNU_SOURCE
#include "h264_stream.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static h264_stream_t* g_h = NULL;
static char g_sink[65536];

static void init_once(void)
{
    if (g_h == NULL)
    {
        /* Swallow the library's debug output (into an in-memory sink) so the
         * fuzzer is not throttled by printing to stdout. */
        h264_dbgfile = fmemopen(g_sink, sizeof(g_sink), "w");
        if (h264_dbgfile == NULL) { h264_dbgfile = stderr; }
        g_h = h264_new();
    }
}

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    init_once();
    if (h264_dbgfile != stderr) { fseek(h264_dbgfile, 0L, SEEK_SET); }
    if (size == 0 || size > (32 * 1024 * 1024)) { return 0; }

    uint8_t* buf = (uint8_t*)malloc(size);
    if (buf == NULL) { return 0; }
    memcpy(buf, data, size);

    uint8_t* p = buf;
    int sz = (int)size;
    int nal_start, nal_end;

    while (find_nal_unit(p, sz, &nal_start, &nal_end) > 0)
    {
        p += nal_start;
        read_debug_nal_unit(g_h, p, nal_end - nal_start);
        p += (nal_end - nal_start);
        sz -= nal_end;
        if (sz <= 0) { break; }
    }

    free(buf);
    return 0;
}

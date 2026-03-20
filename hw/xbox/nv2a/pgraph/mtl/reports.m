/*
 * Metal Renderer - GPU Reports
 *
 * Handles GPU report queries (zpass, etc.)
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include "qemu/osdep.h"

#include <stdio.h>
#include <stdbool.h>

typedef struct {
    bool clear;
    uint32_t parameter;
    uint32_t query_count;
} MTLQueryReport;

void pgraph_mtl_init_reports(PGRAPHMTLState *r)
{
    fprintf(stderr, "Metal: Initializing reports\n");

    if (!r || !r->device) {
        return;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;

    r->max_queries_in_flight = 1024;
    r->num_queries_in_flight = 0;
    r->query_in_flight = false;
    r->zpass_pixel_count_result = 0;
    r->report_queue = g_array_new(false, false, sizeof(MTLQueryReport));
    r->visibility_result_buffer = (void *)
        [device newBufferWithLength:r->max_queries_in_flight * sizeof(uint64_t)
                            options:MTLResourceStorageModeShared];

    if (r->visibility_result_buffer) {
        id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)r->visibility_result_buffer;
        memset(buffer.contents, 0, buffer.length);
    }
}

void pgraph_mtl_await_reports(PGRAPHMTLState *r)
{
    if (!r) {
        return;
    }

    if (r->command_buffer) {
        id<MTLCommandBuffer> buffer = (__bridge id<MTLCommandBuffer>)r->command_buffer;
        [buffer waitUntilCompleted];
    }
}

uint32_t pgraph_mtl_copy_query_results(PGRAPHMTLState *r, uint64_t *dst,
                                       uint32_t max_results)
{
    if (!r || !r->visibility_result_buffer || !dst) {
        return 0;
    }

    id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)r->visibility_result_buffer;
    uint32_t count = MIN(r->num_queries_in_flight, max_results);
    memcpy(dst, buffer.contents, count * sizeof(uint64_t));
    memset(buffer.contents, 0, buffer.length);
    return count;
}

void pgraph_mtl_destroy_reports(PGRAPHMTLState *r)
{
    if (!r) {
        return;
    }

    if (r->report_queue) {
        g_array_free((GArray *)r->report_queue, true);
        r->report_queue = NULL;
    }

    if (r->visibility_result_buffer) {
        r->visibility_result_buffer = nil;
        r->visibility_result_buffer = NULL;
    }
}

#endif

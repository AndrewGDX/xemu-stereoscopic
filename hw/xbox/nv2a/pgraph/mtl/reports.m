/*
 * Metal Renderer - GPU Reports
 *
 * Handles GPU report queries (zpass, etc.)
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include <stdio.h>
#include <stdbool.h>

void pgraph_mtl_init_reports(PGRAPHMTLState *r)
{
    fprintf(stderr, "Metal: Initializing reports\n");
}

void pgraph_mtl_await_reports(PGRAPHMTLState *r)
{
    if (!r || !r->command_queue) {
        return;
    }
    
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)r->command_queue;
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    [buffer commit];
    [buffer waitUntilCompleted];
}

void pgraph_mtl_download_reports(PGRAPHMTLState *r)
{
    (void)r;
}

#endif

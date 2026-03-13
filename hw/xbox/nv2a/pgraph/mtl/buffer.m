/*
 * Metal Renderer - Buffer Management
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include <stdio.h>

#define VERTEX_BUFFER_SIZE (64 * 1024 * 1024)  // 64MB
#define INDEX_BUFFER_SIZE (16 * 1024 * 1024)     // 16MB
#define UNIFORM_BUFFER_SIZE (16 * 1024 * 1024)    // 16MB
#define STAGING_BUFFER_SIZE (32 * 1024 * 1024)    // 32MB

void pgraph_mtl_init_buffers(PGRAPHMTLState *r)
{
    if (!r->device) {
        fprintf(stderr, "Metal: No device, cannot allocate buffers\n");
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    
    id<MTLBuffer> vertexBuf = [device newBufferWithLength:VERTEX_BUFFER_SIZE
                                                options:MTLResourceStorageModeShared];
    r->vertex_buffer = (__bridge void *)vertexBuf;
    
    id<MTLBuffer> indexBuf = [device newBufferWithLength:INDEX_BUFFER_SIZE
                                             options:MTLResourceStorageModeShared];
    r->index_buffer = (__bridge void *)indexBuf;
    
    id<MTLBuffer> uniformBuf = [device newBufferWithLength:UNIFORM_BUFFER_SIZE
                                                options:MTLResourceStorageModeShared];
    r->uniform_buffer = (__bridge void *)uniformBuf;
    
    id<MTLBuffer> stagingBuf = [device newBufferWithLength:STAGING_BUFFER_SIZE
                                                  options:MTLResourceStorageModeShared];
    r->staging_buffer = (__bridge void *)stagingBuf;
    
    fprintf(stderr, "Metal: Allocated buffers (vertex: %dMB, index: %dMB, uniform: %dMB, staging: %dMB)\n",
            VERTEX_BUFFER_SIZE / 1024 / 1024,
            INDEX_BUFFER_SIZE / 1024 / 1024,
            UNIFORM_BUFFER_SIZE / 1024 / 1024,
            STAGING_BUFFER_SIZE / 1024 / 1024);
}

void pgraph_mtl_destroy_buffers(PGRAPHMTLState *r)
{
    if (r->vertex_buffer) {
        r->vertex_buffer = nil;
    }
    if (r->index_buffer) {
        r->index_buffer = nil;
    }
    if (r->uniform_buffer) {
        r->uniform_buffer = nil;
    }
    if (r->staging_buffer) {
        r->staging_buffer = nil;
    }
    
    fprintf(stderr, "Metal: Destroyed buffers\n");
}

#endif

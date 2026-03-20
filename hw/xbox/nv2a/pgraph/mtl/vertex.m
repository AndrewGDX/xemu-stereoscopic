/*
 * Metal Renderer - Vertex Processing
 *
 * Manages vertex buffer binding and processing
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include <stdio.h>

void pgraph_mtl_bind_vertex_attributes(PGRAPHMTLState *r, unsigned int min_element,
                                      unsigned int max_element)
{
    if (!r->render_encoder) {
        return;
    }
    
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)r->render_encoder;
    
    if (r->vertex_buffer) {
        id<MTLBuffer> vertexBuffer = (__bridge id<MTLBuffer>)r->vertex_buffer;
        [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    }
    
    if (r->uniform_buffer) {
        id<MTLBuffer> uniformBuffer = (__bridge id<MTLBuffer>)r->uniform_buffer;
        [encoder setVertexBuffer:uniformBuffer offset:0 atIndex:1];
    }
}

static void pgraph_mtl_update_vertex_buffer(PGRAPHMTLState *r, const void *data,
                                            size_t size, size_t offset)
{
    if (!r->vertex_buffer || !data || size == 0) {
        return;
    }
    
    id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)r->vertex_buffer;
    
    if (offset + size > buffer.length) {
        return;
    }
    
    memcpy(buffer.contents + offset, data, size);
}

static void pgraph_mtl_update_index_buffer(PGRAPHMTLState *r, const void *data,
                                           size_t size, size_t offset)
{
    if (!r->index_buffer || !data || size == 0) {
        return;
    }
    
    id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)r->index_buffer;
    
    if (offset + size > buffer.length) {
        return;
    }
    
    memcpy(buffer.contents + offset, data, size);
}

void pgraph_mtl_update_vertex_buffer_from_data(PGRAPHMTLState *r, const void *data, size_t size, size_t offset)
{
    if (!r->vertex_buffer || !data || size == 0) {
        return;
    }
    
    id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)r->vertex_buffer;
    
    if (offset + size > buffer.length) {
        return;
    }
    
    memcpy(buffer.contents + offset, data, size);
}

#endif

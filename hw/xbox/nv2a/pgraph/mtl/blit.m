/*
 * Metal Renderer - Blit Operations
 *
 * Handles image blit operations for video overlay and surface copying
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include <stdio.h>
#include <string.h>
#include <stdbool.h>

#ifndef NV2A_STATE_C
#define NV2A_STATE_C
struct NV2AState;
typedef struct NV2AState NV2AState;
#endif

void pgraph_mtl_image_blit(PGRAPHMTLState *r)
{
    if (!r || !r->device || !r->command_queue) {
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)r->command_queue;
    
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    
    if (!blitEncoder) {
        return;
    }
    
    id<MTLTexture> srcTex = (__bridge id<MTLTexture>)r->surface_color;
    id<MTLTexture> dstTex = (__bridge id<MTLTexture>)r->display_texture;
    
    if (srcTex && dstTex && srcTex.width == dstTex.width && srcTex.height == dstTex.height) {
        MTLSize size = MTLSizeMake(srcTex.width, srcTex.height, 1);
        [blitEncoder copyFromTexture:srcTex
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:size
                            toTexture:dstTex
                     destinationSlice:0
                     destinationLevel:0
                    destinationOrigin:MTLOriginMake(0, 0, 0)];
    }
    
    [blitEncoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
}

#endif

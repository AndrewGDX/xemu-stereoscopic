/*
 * Metal Renderer - Command Buffers
 *
 * Manages command buffer creation and submission
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include <stdio.h>

void pgraph_mtl_begin_command_buffer(PGRAPHMTLState *r)
{
    if (!r->device || !r->command_queue) {
        return;
    }
    
    if (r->render_encoder) {
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)r->command_queue;
    
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    r->command_buffer = (__bridge void *)commandBuffer;
    
    if (!r->surface_color) {
        return;
    }
    
    id<MTLTexture> colorTex = (__bridge id<MTLTexture>)r->surface_color;
    id<MTLTexture> depthTex = r->surface_zeta ? (__bridge id<MTLTexture>)r->surface_zeta : nil;
    
    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    passDesc.colorAttachments[0].texture = colorTex;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    
    if (depthTex) {
        passDesc.depthAttachment.texture = depthTex;
        passDesc.depthAttachment.loadAction = MTLLoadActionClear;
        passDesc.depthAttachment.storeAction = MTLStoreActionStore;
        passDesc.depthAttachment.clearDepth = 1.0;
    }
    
    r->render_pass_descriptor = (__bridge void *)passDesc;
    
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDesc];
    r->render_encoder = (__bridge void *)encoder;
    
    if (r->viewport_width > 0 && r->viewport_height > 0) {
        MTLViewport viewport = {
            .originX = 0,
            .originY = 0,
            .width = r->viewport_width,
            .height = r->viewport_height,
            .znear = 0.0,
            .zfar = 1.0
        };
        [encoder setViewport:viewport];
    }
    
    r->command_buffer_in_progress = true;
    r->render_pass_active = true;
}

void pgraph_mtl_end_command_buffer(PGRAPHMTLState *r)
{
    if (r->render_encoder) {
        id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)r->render_encoder;
        [encoder endEncoding];
        r->render_encoder = NULL;
    }
    
    r->render_pass_active = false;
}

void pgraph_mtl_submit_command_buffer(PGRAPHMTLState *r)
{
    if (!r->command_buffer) {
        return;
    }
    
    id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)r->command_buffer;
    
    [commandBuffer commit];
    
    r->command_buffer = NULL;
    r->command_buffer_in_progress = false;
}

void pgraph_mtl_wait_idle(PGRAPHMTLState *r)
{
    if (!r->command_queue) {
        return;
    }
    
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)r->command_queue;
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    [buffer commit];
    [buffer waitUntilCompleted];
}

#endif

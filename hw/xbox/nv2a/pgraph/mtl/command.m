/*
 * Metal Renderer - Command Buffers
 *
 * Manages command buffer creation and submission
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include "hw/xbox/nv2a/nv2a_regs.h"

#include <stdio.h>

void pgraph_mtl_begin_command_buffer(PGRAPHMTLState *r)
{
    if (!r->device || !r->command_queue) {
        return;
    }
    
    if (r->render_encoder) {
        return;
    }
    
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
    passDesc.colorAttachments[0].loadAction =
        r->clear_color_pending ? MTLLoadActionClear : MTLLoadActionLoad;
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(r->clear_color[0],
                                                                 r->clear_color[1],
                                                                 r->clear_color[2],
                                                                 r->clear_color[3]);
    
    if (depthTex) {
        passDesc.depthAttachment.texture = depthTex;
        passDesc.depthAttachment.loadAction =
            r->clear_zeta_pending ? MTLLoadActionClear : MTLLoadActionLoad;
        passDesc.depthAttachment.storeAction = MTLStoreActionStore;
        passDesc.depthAttachment.clearDepth = r->clear_depth;
        if (r->zeta_format == NV097_SET_SURFACE_FORMAT_ZETA_Z24S8) {
            passDesc.stencilAttachment.texture = depthTex;
            passDesc.stencilAttachment.loadAction =
                r->clear_zeta_pending ? MTLLoadActionClear : MTLLoadActionLoad;
            passDesc.stencilAttachment.storeAction = MTLStoreActionStore;
            passDesc.stencilAttachment.clearStencil = r->clear_stencil;
        }
    }

    if (r->visibility_result_buffer) {
        passDesc.visibilityResultBuffer = (__bridge id<MTLBuffer>)r->visibility_result_buffer;
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
    r->clear_pending = false;
    r->clear_color_pending = false;
    r->clear_zeta_pending = false;
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

void pgraph_mtl_set_clear_scissor(PGRAPHMTLState *r, uint32_t x, uint32_t y, uint32_t width, uint32_t height)
{
    if (!r || !r->render_encoder) {
        return;
    }
    
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)r->render_encoder;
    MTLScissorRect scissor = {
        .x = x,
        .y = y,
        .width = width,
        .height = height
    };
    [encoder setScissorRect:scissor];
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

void pgraph_mtl_sync_texture_for_cpu(PGRAPHMTLState *r, void *texture)
{
    if (!r || !r->command_queue || !texture) {
        return;
    }

    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)r->command_queue;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;

    if (!tex) {
        return;
    }

    if (@available(macOS 10.15, *)) {
        if (tex.storageMode != MTLStorageModeManaged) {
            return;
        }
    }

    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    [blitEncoder synchronizeResource:tex];
    [blitEncoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
}

#endif

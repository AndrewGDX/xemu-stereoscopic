/*
 * Metal Renderer - Display
 *
 * Handles CAMetalLayer integration for SDL2 display
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>

#include <stdio.h>
#include <stdbool.h>

void pgraph_mtl_init_display(PGRAPHMTLState *r)
{
    fprintf(stderr, "Metal: Initializing display\n");
    
    if (!r->device) {
        fprintf(stderr, "Metal: No device for display init\n");
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    
    r->display_width = 640;
    r->display_height = 480;
    r->display_valid = false;
    
    MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:r->display_width
                                                                                   height:r->display_height
                                                                                mipmapped:NO];
    texDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    texDesc.storageMode = MTLStorageModeManaged;
    
    r->display_texture = (__bridge void *)[device newTextureWithDescriptor:texDesc];
    
    MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];
    samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    
    r->sampler_state = (__bridge void *)[device newSamplerStateWithDescriptor:samplerDesc];
    
    fprintf(stderr, "Metal: Display initialized (%dx%d)\n", r->display_width, r->display_height);
}

void pgraph_mtl_display_render(PGRAPHMTLState *r)
{
    bool refreshed;

    if (!r) {
        return;
    }

    if (!r->device || !r->command_queue) {
        return;
    }
    
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)r->command_queue;
    
    dispatch_semaphore_wait(r->frame_semaphore, DISPATCH_TIME_FOREVER);
    
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    
    __block dispatch_semaphore_t sem = r->frame_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        dispatch_semaphore_signal(sem);
    }];

    refreshed = pgraph_mtl_display_refresh(r);
    if (!refreshed) {
        r->display_valid = false;
    }
    
    r->current_frame_index = (r->current_frame_index + 1) % 3;
    r->frame_count++;
    
    [commandBuffer commit];
}

bool pgraph_mtl_display_refresh(PGRAPHMTLState *r)
{
    if (!r || !r->device || !r->command_queue || !r->surface_color) {
        return false;
    }
    
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)r->command_queue;
    id<MTLTexture> surfaceTex = (__bridge id<MTLTexture>)r->surface_color;
    id<MTLTexture> displayTex = (__bridge id<MTLTexture>)r->display_texture;

    if (!surfaceTex || !displayTex) {
        return false;
    }

    if (r->display_width != surfaceTex.width ||
        r->display_height != surfaceTex.height) {
        return false;
    }
    
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    
    MTLSize sourceSize = MTLSizeMake(surfaceTex.width, surfaceTex.height, 1);
    
    [blitEncoder copyFromTexture:surfaceTex
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:sourceSize
                        toTexture:displayTex
                 destinationSlice:0
                 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
    
    [blitEncoder synchronizeResource:displayTex];
    
    [blitEncoder endEncoding];
    
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    r->display_valid = true;
    return true;
}

void pgraph_mtl_display_present(PGRAPHMTLState *r)
{
    (void)pgraph_mtl_display_refresh(r);
}

void pgraph_mtl_display_set_size(PGRAPHMTLState *r, uint32_t width, uint32_t height)
{
    if (!r->device) {
        return;
    }
    
    if (r->display_width == width && r->display_height == height) {
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)r->display_texture;
    if (tex) {
        tex = nil;
    }
    r->display_texture = NULL;
    
    r->display_width = width;
    r->display_height = height;
    r->display_valid = false;
    
    MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    texDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    texDesc.storageMode = MTLStorageModeManaged;
    
    r->display_texture = (__bridge void *)[device newTextureWithDescriptor:texDesc];
    
    fprintf(stderr, "Metal: Display size changed to %dx%d\n", width, height);
}

bool pgraph_mtl_display_upload(PGRAPHMTLState *r, const void *data,
                               uint32_t width, uint32_t height,
                               uint32_t bytes_per_row)
{
    if (!r || !r->display_texture || !data || !width || !height) {
        return false;
    }

    id<MTLTexture> tex = (__bridge id<MTLTexture>)r->display_texture;
    if (!tex || tex.width != width || tex.height != height) {
        return false;
    }

    [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
           mipmapLevel:0
             withBytes:data
           bytesPerRow:bytes_per_row];
    r->display_valid = true;
    return true;
}

void pgraph_mtl_display_destroy(PGRAPHMTLState *r)
{
    if (r->display_texture) {
        r->display_texture = nil;
    }
    r->display_valid = false;
}

#endif

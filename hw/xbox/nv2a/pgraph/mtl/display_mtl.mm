/*
 * Metal Display - C-compatible wrapper for display rendering
 */

#include "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>
#include <stdbool.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

static SDL_MetalView metal_view = NULL;
static void *cached_device = NULL;

void pgraph_mtl_set_display_device(void *device)
{
    cached_device = device;
}

void pgraph_mtl_render_display_to_metal_layer(void *window, void *display_texture)
{
    if (!window || !display_texture) {
        return;
    }

    SDL_Window *sdl_window = (SDL_Window *)window;
    
    if (!metal_view) {
        metal_view = SDL_Metal_CreateView(sdl_window);
        if (!metal_view) {
            return;
        }
    }

    CAMetalLayer *metal_layer = (CAMetalLayer *)SDL_Metal_GetLayer(metal_view);
    if (!metal_layer) {
        return;
    }

    id<MTLDevice> device = cached_device ? (__bridge id<MTLDevice>)cached_device : nil;
    if (!device) {
        device = MTLCreateSystemDefaultDevice();
    }
    metal_layer.device = device;
    metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metal_layer.framebufferOnly = NO;

    id<CAMetalDrawable> drawable = [metal_layer nextDrawable];
    if (!drawable) {
        return;
    }

    id<MTLTexture> tex = (__bridge id<MTLTexture>)display_texture;

    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    MTLSize size = MTLSizeMake(tex.width, tex.height, 1);
    [blit copyFromTexture:tex
             sourceSlice:0
             sourceLevel:0
            sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:size
                toTexture:drawable.texture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    [cmd presentDrawable:drawable];
    [cmd commit];
    [cmd waitUntilCompleted];
}

bool pgraph_mtl_display_copy_texture(void *texture, void *dst,
                                     size_t bytes_per_row,
                                     uint32_t width, uint32_t height)
{
    if (!texture || !dst || width == 0 || height == 0) {
        return false;
    }

    id<MTLTexture> src = (__bridge id<MTLTexture>)texture;
    if (!src || src.width < width || src.height < height) {
        return false;
    }

    [src getBytes:dst
      bytesPerRow:bytes_per_row
       fromRegion:MTLRegionMake2D(0, 0, width, height)
      mipmapLevel:0];

    return true;
}

#ifdef __cplusplus
}
#endif

#endif

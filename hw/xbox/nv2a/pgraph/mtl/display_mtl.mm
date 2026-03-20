/*
 * Metal Display - C-compatible wrapper for display rendering
 */

#include "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <OpenGL/OpenGL.h>

#include <SDL3/SDL.h>
#include <epoxy/gl.h>
#include <stdbool.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

static void *cached_device = NULL;
static void *cached_queue = NULL;
static IOSurfaceRef cached_surface = NULL;
static void *cached_present_texture = NULL;
static GLuint cached_gl_texture = 0;
static uint32_t cached_width;
static uint32_t cached_height;

void pgraph_mtl_set_display_device(void *device)
{
    cached_device = device;
}

static void pgraph_mtl_destroy_cached_queue(void)
{
    if (cached_queue) {
        cached_queue = NULL;
    }
}

static void pgraph_mtl_destroy_cached_gl_texture(void)
{
    if (cached_gl_texture != 0 && CGLGetCurrentContext()) {
        glDeleteTextures(1, &cached_gl_texture);
    }
    cached_gl_texture = 0;
}

static void pgraph_mtl_destroy_cached_surface(void)
{
    if (cached_surface) {
        CFRelease(cached_surface);
        cached_surface = NULL;
    }

    cached_present_texture = NULL;
    cached_width = 0;
    cached_height = 0;
}

static bool pgraph_mtl_prepare_gl_interop_texture(id<MTLDevice> device,
                                                  uint32_t width,
                                                  uint32_t height)
{
    NSDictionary *props;
    MTLTextureDescriptor *desc;
    CGLContextObj cgl_ctx;
    CGLError gl_err;

    if (!device || width == 0 || height == 0) {
        return false;
    }

    if (cached_surface && cached_width == width && cached_height == height &&
        cached_present_texture && cached_gl_texture != 0) {
        return true;
    }

    pgraph_mtl_destroy_cached_gl_texture();
    pgraph_mtl_destroy_cached_surface();

    props = @{
        (NSString *)kIOSurfaceWidth: @(width),
        (NSString *)kIOSurfaceHeight: @(height),
        (NSString *)kIOSurfaceBytesPerElement: @4,
        (NSString *)kIOSurfaceBytesPerRow: @((size_t)width * 4),
        (NSString *)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
    };
    cached_surface = IOSurfaceCreate((CFDictionaryRef)props);
    if (!cached_surface) {
        return false;
    }

    desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                              width:width
                                                             height:height
                                                          mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                 MTLTextureUsageRenderTarget;
    cached_present_texture = (__bridge void *)[device newTextureWithDescriptor:desc
                                                                     iosurface:cached_surface
                                                                         plane:0];
    if (!cached_present_texture) {
        pgraph_mtl_destroy_cached_surface();
        return false;
    }

    cgl_ctx = CGLGetCurrentContext();
    if (!cgl_ctx) {
        pgraph_mtl_destroy_cached_surface();
        return false;
    }

    glGenTextures(1, &cached_gl_texture);
    glBindTexture(GL_TEXTURE_2D, cached_gl_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    gl_err = CGLTexImageIOSurface2D(cgl_ctx, GL_TEXTURE_2D, GL_RGBA8,
                                    width, height, GL_BGRA,
                                    GL_UNSIGNED_INT_8_8_8_8_REV,
                                    cached_surface, 0);
    glBindTexture(GL_TEXTURE_2D, 0);
    if (gl_err != kCGLNoError) {
        pgraph_mtl_destroy_cached_gl_texture();
        pgraph_mtl_destroy_cached_surface();
        return false;
    }

    cached_width = width;
    cached_height = height;
    return true;
}

void pgraph_mtl_destroy_display_presenter(void)
{
    pgraph_mtl_destroy_cached_queue();
    pgraph_mtl_destroy_cached_gl_texture();
    pgraph_mtl_destroy_cached_surface();
    cached_device = NULL;
}

unsigned int pgraph_mtl_display_get_gl_texture(void *device_handle,
                                               void *display_texture,
                                               uint32_t width,
                                               uint32_t height)
{
    id<MTLDevice> device;
    id<MTLTexture> src;
    id<MTLTexture> dst;
    id<MTLCommandQueue> queue;
    id<MTLCommandBuffer> cmd;
    id<MTLBlitCommandEncoder> blit;

    if (!display_texture || width == 0 || height == 0) {
        return 0;
    }

    device = device_handle ? (__bridge id<MTLDevice>)device_handle : nil;
    if (!device) {
        device = MTLCreateSystemDefaultDevice();
    }
    if (!device) {
        return 0;
    }
    cached_device = (__bridge void *)device;

    if (!pgraph_mtl_prepare_gl_interop_texture(device, width, height)) {
        return 0;
    }

    src = (__bridge id<MTLTexture>)display_texture;
    dst = (__bridge id<MTLTexture>)cached_present_texture;
    if (!src || !dst) {
        return 0;
    }

    queue = cached_queue ? (__bridge id<MTLCommandQueue>)cached_queue : nil;
    if (!queue || queue.device != device) {
        queue = [device newCommandQueue];
        if (!queue) {
            return 0;
        }
        cached_queue = (__bridge void *)queue;
    }

    cmd = [queue commandBuffer];
    if (!cmd) {
        return 0;
    }
    blit = [cmd blitCommandEncoder];
    if (!blit) {
        return 0;
    }

    [blit copyFromTexture:src
             sourceSlice:0
             sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                 toTexture:dst
          destinationSlice:0
          destinationLevel:0
         destinationOrigin:MTLOriginMake(0, 0, 0)];
    if (@available(macOS 10.15, *)) {
        if (dst.storageMode == MTLStorageModeManaged) {
            [blit synchronizeResource:dst];
        }
    }
    [blit endEncoding];

    [cmd commit];
    [cmd waitUntilCompleted];

    return cached_gl_texture;
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

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
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

static void *cached_device = NULL;
static void *cached_queue = NULL;
static void *cached_staging_buffer = NULL;
static uint8_t *cached_cpu_buffer = NULL;
static GLuint cached_gl_texture = 0;
static uint32_t cached_width;
static uint32_t cached_height;
static size_t cached_buffer_size;

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
    if (cached_gl_texture != 0) {
        CGLContextObj cgl_ctx = CGLGetCurrentContext();
        if (cgl_ctx) {
            glDeleteTextures(1, &cached_gl_texture);
        }
    }
    cached_gl_texture = 0;
}

static void pgraph_mtl_destroy_staging_buffer(void)
{
    if (cached_cpu_buffer) {
        free(cached_cpu_buffer);
        cached_cpu_buffer = NULL;
    }
    cached_staging_buffer = NULL;
    cached_buffer_size = 0;
}

static bool pgraph_mtl_prepare_gl_texture(uint32_t width, uint32_t height)
{
    CGLContextObj cgl_ctx;

    if (width == 0 || height == 0) {
        return false;
    }

    if (cached_gl_texture != 0 && cached_width == width && cached_height == height) {
        return true;
    }

    pgraph_mtl_destroy_cached_gl_texture();

    cgl_ctx = CGLGetCurrentContext();
    if (!cgl_ctx) {
        fprintf(stderr, "Metal: No GL context current for texture creation\n");
        return false;
    }

    glGenTextures(1, &cached_gl_texture);
    glBindTexture(GL_TEXTURE_2D, cached_gl_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_BGRA,
                 GL_UNSIGNED_INT_8_8_8_8_REV, NULL);
    glBindTexture(GL_TEXTURE_2D, 0);

    if (glGetError() != GL_NO_ERROR) {
        fprintf(stderr, "Metal: Failed to create GL texture\n");
        pgraph_mtl_destroy_cached_gl_texture();
        return false;
    }

    cached_width = width;
    cached_height = height;
    cached_buffer_size = (size_t)width * height * 4;
    cached_cpu_buffer = (uint8_t *)malloc(cached_buffer_size);
    
    if (!cached_cpu_buffer) {
        fprintf(stderr, "Metal: Failed to allocate CPU buffer\n");
        pgraph_mtl_destroy_cached_gl_texture();
        return false;
    }

    fprintf(stderr, "Metal: CPU readback path prepared (%dx%d)\n", width, height);
    return true;
}

void pgraph_mtl_destroy_display_presenter(void)
{
    pgraph_mtl_destroy_cached_queue();
    pgraph_mtl_destroy_cached_gl_texture();
    pgraph_mtl_destroy_staging_buffer();
    cached_device = NULL;
}

unsigned int pgraph_mtl_display_get_gl_texture(void *device_handle,
                                               void *display_texture,
                                               uint32_t width,
                                               uint32_t height)
{
    id<MTLDevice> device;
    id<MTLTexture> src;
    id<MTLCommandQueue> queue;
    id<MTLCommandBuffer> cmd;
    id<MTLBlitCommandEncoder> blit;
    id<MTLBuffer> staging_buf;
    size_t buffer_size;

    if (!display_texture || width == 0 || height == 0) {
        return 0;
    }

    device = device_handle ? (__bridge id<MTLDevice>)device_handle : nil;
    if (!device) {
        fprintf(stderr, "Metal: No device for get_gl_texture\n");
        return 0;
    }

    buffer_size = (size_t)width * height * 4;
    if (!pgraph_mtl_prepare_gl_texture(width, height)) {
        fprintf(stderr, "Metal: Failed to prepare GL texture\n");
        return 0;
    }

    src = (__bridge id<MTLTexture>)display_texture;
    if (!src) {
        fprintf(stderr, "Metal: No source texture\n");
        return 0;
    }

    if (src.storageMode != MTLStorageModeManaged) {
        queue = cached_queue ? (__bridge id<MTLCommandQueue>)cached_queue : nil;
        if (!queue || queue.device != device) {
            queue = [device newCommandQueue];
            if (!queue) {
                fprintf(stderr, "Metal: Failed to create command queue\n");
                return 0;
            }
            cached_queue = (__bridge void *)queue;
        }

        id<MTLBuffer> staging_buf = [device newBufferWithLength:buffer_size options:MTLStorageModeManaged];
        if (!staging_buf) {
            fprintf(stderr, "Metal: Failed to create staging buffer\n");
            return 0;
        }

        cmd = [queue commandBuffer];
        if (!cmd) {
            fprintf(stderr, "Metal: Failed to create command buffer\n");
            return 0;
        }

        blit = [cmd blitCommandEncoder];
        if (!blit) {
            fprintf(stderr, "Metal: Failed to create blit encoder\n");
            return 0;
        }

        MTLSize size = MTLSizeMake(width, height, 1);
        [blit copyFromTexture:src
                 sourceSlice:0
                 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:size
                    toBuffer:staging_buf
           destinationOffset:0
          destinationBytesPerRow:width * 4
        destinationBytesPerImage:buffer_size];

        [blit synchronizeResource:staging_buf];
        [blit endEncoding];

        [cmd commit];
        [cmd waitUntilCompleted];

        memcpy(cached_cpu_buffer, [staging_buf contents], buffer_size);
    } else {
        [src getBytes:cached_cpu_buffer
          bytesPerRow:width * 4
           fromRegion:MTLRegionMake2D(0, 0, width, height)
          mipmapLevel:0];
    }

    CGLContextObj cgl_ctx = CGLGetCurrentContext();
    if (cgl_ctx) {
        glBindTexture(GL_TEXTURE_2D, cached_gl_texture);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_BGRA,
                        GL_UNSIGNED_INT_8_8_8_8_REV, cached_cpu_buffer);
        glBindTexture(GL_TEXTURE_2D, 0);
    }

    return cached_gl_texture;
}

bool pgraph_mtl_display_copy_texture(void *texture, void *dst,
                                     size_t bytes_per_row,
                                     uint32_t width,
                                     uint32_t height)
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

/*
 * Metal Renderer - Device Initialization
 *
 * Uses Metal API
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <stdio.h>
#include <stdbool.h>

#ifndef ERROR_C
#define ERROR_C
struct Error;
typedef struct Error Error;
#endif

void pgraph_mtl_init_device(PGRAPHMTLState *r, Error **errp)
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        fprintf(stderr, "Metal: Failed to create device\n");
        r->initialized = false;
        return;
    }
    
    fprintf(stderr, "Metal: Created device: %s\n", [device.name UTF8String]);
    
    r->device = (__bridge void *)device;
    
    id<MTLCommandQueue> commandQueue = [device newCommandQueue];
    if (!commandQueue) {
        fprintf(stderr, "Metal: Failed to create command queue\n");
        r->device = nil;
        r->initialized = false;
        return;
    }
    
    r->command_queue = (__bridge void *)commandQueue;
    
    r->command_buffer_semaphore = dispatch_semaphore_create(1);
    r->frame_semaphore = dispatch_semaphore_create(3);
    r->current_frame_index = 0;
    r->frame_count = 0;
    
    r->color_format = MTLPixelFormatBGRA8Unorm;
    r->zeta_format = MTLPixelFormatDepth32Float;
    r->viewport_width = 640;
    r->viewport_height = 480;
    
    r->initialized = true;
    fprintf(stderr, "Metal device initialized successfully\n");
}

void pgraph_mtl_finalize_device(PGRAPHMTLState *r)
{
    if (r->command_buffer) {
        id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)r->command_buffer;
        [cb waitUntilCompleted];
        r->command_buffer = nil;
    }
    
    if (r->render_encoder) {
        r->render_encoder = nil;
    }
    
    if (r->blit_encoder) {
        r->blit_encoder = nil;
    }
    
    if (r->command_queue) {
        r->command_queue = nil;
    }
    
    if (r->device) {
        r->device = nil;
    }
    
    if (r->command_buffer_semaphore) {
        dispatch_release(r->command_buffer_semaphore);
        r->command_buffer_semaphore = NULL;
    }
    
    if (r->frame_semaphore) {
        dispatch_release(r->frame_semaphore);
        r->frame_semaphore = NULL;
    }
    
    r->initialized = false;
}

#endif

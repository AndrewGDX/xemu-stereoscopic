/*
 * Metal C API Stub Implementation
 *
 * Provides stub implementations for compilation
 * Actual Metal functionality to be added later
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void *MTLCreateSystemDefaultDevice_C(void)
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device) {
        fprintf(stderr, "Metal: Created device: %s\n", [[device name] UTF8String]);
    }
    return (__bridge void *)device;
}

const char* MTLDevice_getName_C(void *device)
{
    if (!device) {
        return "None";
    }
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    return [[d name] UTF8String];
}

void *MTLDevice_newCommandQueue_C(void *device)
{
    if (!device) {
        return NULL;
    }
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    id<MTLCommandQueue> queue = [d newCommandQueue];
    return (__bridge void *)queue;
}

void *MTLCommandQueue_commandBufferWithReference_C(void *queue)
{
    if (!queue) {
        return NULL;
    }
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    id<MTLCommandBuffer> buffer = [q commandBuffer];
    return (__bridge void *)buffer;
}

void MTLCommandBuffer_commit_C(void *buffer)
{
    if (!buffer) {
        return;
    }
    id<MTLCommandBuffer> b = (__bridge id<MTLCommandBuffer>)buffer;
    [b commit];
}

void MTLCommandBuffer_waitUntilCompleted_C(void *buffer)
{
    if (!buffer) {
        return;
    }
    id<MTLCommandBuffer> b = (__bridge id<MTLCommandBuffer>)buffer;
    [b waitUntilCompleted];
}

#endif

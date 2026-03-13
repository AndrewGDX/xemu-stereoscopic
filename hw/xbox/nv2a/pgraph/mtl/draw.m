/*
 * Metal Renderer - Draw Operations
 *
 * Manages render pipelines and drawing operations
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include <stdio.h>
#include <string.h>

void pgraph_mtl_init_pipelines(PGRAPHMTLState *r)
{
    fprintf(stderr, "Metal: Initializing pipelines\n");
    
    if (!r->device || !r->shader_library) {
        fprintf(stderr, "Metal: No device or shader library for pipeline init\n");
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    id<MTLLibrary> library = (__bridge id<MTLLibrary>)r->shader_library;
    
    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"vertex_main"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"fragment_main"];
    
    if (!vertexFunc || !fragmentFunc) {
        fprintf(stderr, "Metal: Failed to get shader functions\n");
        return;
    }
    
    MTLVertexDescriptor *vertexDesc = [[MTLVertexDescriptor alloc] init];
    
    vertexDesc.attributes[0].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[0].offset = 0;
    vertexDesc.attributes[0].bufferIndex = 0;
    
    vertexDesc.attributes[1].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[1].offset = 16;
    vertexDesc.attributes[1].bufferIndex = 0;
    
    vertexDesc.attributes[2].format = MTLVertexFormatFloat2;
    vertexDesc.attributes[2].offset = 32;
    vertexDesc.attributes[2].bufferIndex = 0;
    
    vertexDesc.attributes[3].format = MTLVertexFormatFloat3;
    vertexDesc.attributes[3].offset = 40;
    vertexDesc.attributes[3].bufferIndex = 0;
    
    vertexDesc.layouts[0].stride = 52;
    vertexDesc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    
    MTLRenderPipelineDescriptor *pipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDesc.vertexFunction = vertexFunc;
    pipelineDesc.fragmentFunction = fragmentFunc;
    pipelineDesc.vertexDescriptor = vertexDesc;
    
    pipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    // isBlendingEnabled is read-only in some Metal versions
    // Use separate blend factor properties instead
    pipelineDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    pipelineDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    pipelineDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pipelineDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    pipelineDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pipelineDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    
    pipelineDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
    
    if (error) {
        fprintf(stderr, "Metal: Failed to create pipeline: %s\n", [[error localizedDescription] UTF8String]);
        return;
    }
    
    r->pipeline_state = (__bridge void *)pipeline;
    
    MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthDesc.depthWriteEnabled = YES;
    
    id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:depthDesc];
    r->depth_stencil_state = (__bridge void *)depthState;
    
    fprintf(stderr, "Metal: Pipelines initialized successfully\n");
}

void pgraph_mtl_destroy_pipelines(PGRAPHMTLState *r)
{
    if (r->pipeline_state) {
        id<MTLRenderPipelineState> pipeline = (__bridge id<MTLRenderPipelineState>)r->pipeline_state;
        pipeline = nil;
        r->pipeline_state = NULL;
    }
    
    if (r->depth_stencil_state) {
        id<MTLDepthStencilState> depthState = (__bridge id<MTLDepthStencilState>)r->depth_stencil_state;
        depthState = nil;
        r->depth_stencil_state = NULL;
    }
    
    if (r->vertex_descriptor) {
        // MTLVertexDescriptor is a struct, not an object - just free the memory
        free(r->vertex_descriptor);
        r->vertex_descriptor = NULL;
    }
}

void pgraph_mtl_draw(PGRAPHMTLState *r, bool is_indexed, uint32_t first_vertex, uint32_t vertex_count)
{
    if (!r->command_buffer || !r->render_encoder || !r->pipeline_state) {
        return;
    }
    
    if (vertex_count == 0) {
        return;
    }
    
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)r->render_encoder;
    id<MTLRenderPipelineState> pipeline = (__bridge id<MTLRenderPipelineState>)r->pipeline_state;
    
    [encoder setRenderPipelineState:pipeline];
    
    if (r->depth_stencil_state) {
        id<MTLDepthStencilState> depthState = (__bridge id<MTLDepthStencilState>)r->depth_stencil_state;
        [encoder setDepthStencilState:depthState];
    }
    
    if (r->vertex_buffer) {
        id<MTLBuffer> vertexBuffer = (__bridge id<MTLBuffer>)r->vertex_buffer;
        [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    }
    
    if (r->uniform_buffer) {
        id<MTLBuffer> uniformBuffer = (__bridge id<MTLBuffer>)r->uniform_buffer;
        [encoder setVertexBuffer:uniformBuffer offset:0 atIndex:1];
    }
    
    if (r->sampler_state) {
        id<MTLSamplerState> sampler = (__bridge id<MTLSamplerState>)r->sampler_state;
        [encoder setFragmentSamplerState:sampler atIndex:0];
    }
    
    if (is_indexed && r->index_buffer) {
        id<MTLBuffer> indexBuffer = (__bridge id<MTLBuffer>)r->index_buffer;
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:vertex_count
                             indexType:MTLIndexTypeUInt32
                       indexBuffer:indexBuffer
                 indexBufferOffset:0];
    } else {
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:first_vertex vertexCount:vertex_count];
    }
}

void pgraph_mtl_draw_inline(PGRAPHMTLState *r, uint32_t vertex_count)
{
    pgraph_mtl_draw(r, false, 0, vertex_count);
}

void pgraph_mtl_clear(PGRAPHMTLState *r, float r_val, float g_val, float b_val, float a_val)
{
    (void)r;
    (void)r_val;
    (void)g_val;
    (void)b_val;
    (void)a_val;
}

#endif

/*
 * Geforce NV2A PGRAPH Metal Renderer - GPU Properties
 *
 * Copyright (c) 2024-2025 Matt Borgerson
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include <stdio.h>
#include <stdbool.h>

typedef struct GPUProperties {
    struct {
        short tri;
        short tri_strip0;
        short tri_strip1;
        short tri_fan;
    } geom_shader_winding;
} GPUProperties;

GPUProperties g_mtl_gpu_properties;

GPUProperties *pgraph_mtl_get_gpu_properties(void)
{
    g_mtl_gpu_properties.geom_shader_winding.tri = 0;
    g_mtl_gpu_properties.geom_shader_winding.tri_strip0 = 0;
    g_mtl_gpu_properties.geom_shader_winding.tri_strip1 = 1;
    g_mtl_gpu_properties.geom_shader_winding.tri_fan = 0;
    
    return &g_mtl_gpu_properties;
}

#endif

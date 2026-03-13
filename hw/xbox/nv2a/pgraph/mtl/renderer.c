/*
 * Geforce NV2A PGRAPH Metal Renderer - Main Implementation
 *
 * Copyright (c) 2024-2025 Matt Borgerson
 *
 * Uses C-compatible Metal API
 */

#include "hw/xbox/nv2a/nv2a_int.h"
#include "hw/xbox/nv2a/pgraph/pgraph.h"
#include "hw/xbox/nv2a/pgraph/texture.h"
#include "renderer.h"

#if TARGET_OS_MAC

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "qemu/osdep.h"
#include "qemu/main-loop.h"
#include "hw/xbox/nv2a/pgraph/pgraph.h"

void pgraph_mtl_init(NV2AState *d, Error **errp)
{
    PGRAPHState *pg = &d->pgraph;

    pg->mtl_renderer_state = (PGRAPHMTLState *)g_malloc0(sizeof(PGRAPHMTLState));
    PGRAPHMTLState *r = pg->mtl_renderer_state;

    pgraph_mtl_init_device(r, errp);
    if (errp && *errp) {
        return;
    }
    
    if (!r->initialized) {
        fprintf(stderr, "Metal: Device initialization failed\n");
        if (errp) {
            error_setg(errp, "Metal: Device initialization failed");
        }
        return;
    }

    pgraph_mtl_init_buffers(r);
    pgraph_mtl_init_surfaces(r);
    pgraph_mtl_init_textures(r);
    pgraph_mtl_shaders_init(r);
    pgraph_mtl_init_pipelines(r);
    pgraph_mtl_init_reports(r);
    pgraph_mtl_init_display(r);

    if (!r->initialized) {
        fprintf(stderr, "Metal: Renderer initialization failed\n");
        if (errp) {
            error_setg(errp, "Metal: Renderer initialization failed");
        }
        return;
    }

    fprintf(stderr, "Metal renderer initialized successfully\n");
}

static void pgraph_mtl_finalize(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }

    pgraph_mtl_display_destroy(r);
    pgraph_mtl_destroy_pipelines(r);
    pgraph_mtl_shaders_destroy(r);
    pgraph_mtl_destroy_textures(r);
    pgraph_mtl_surface_destroy(r);
    pgraph_mtl_destroy_buffers(r);
    pgraph_mtl_finalize_device(r);

    g_free(pg->mtl_renderer_state);
    pg->mtl_renderer_state = NULL;
}

void pgraph_mtl_flush(PGRAPHMTLState *r)
{
    if (r && r->command_buffer_in_progress) {
        r->command_buffer_in_progress = false;
    }
}

void pgraph_mtl_submit(PGRAPHMTLState *r)
{
    if (!r || !r->command_buffer) {
        return;
    }
    pgraph_mtl_submit_command_buffer(r);
}

void pgraph_mtl_clear_report_value(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    pg->zpass_pixel_count_enable = false;
}

void pgraph_mtl_clear_surface(NV2AState *d, uint32_t parameter)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r || !r->render_encoder) {
        return;
    }
    
    bool write_color = (parameter & NV097_CLEAR_SURFACE_COLOR) != 0;
    bool write_zeta = (parameter & (NV097_CLEAR_SURFACE_Z | NV097_CLEAR_SURFACE_STENCIL)) != 0;
    
    if (!write_color && !write_zeta) {
        return;
    }
    
    float rgba[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    uint32_t color_clear = pgraph_reg_r(pg, NV_PGRAPH_COLORCLEARVALUE);
    rgba[0] = ((color_clear >> 16) & 0xFF) / 255.0f;
    rgba[1] = ((color_clear >> 8) & 0xFF) / 255.0f;
    rgba[2] = (color_clear & 0xFF) / 255.0f;
    rgba[3] = ((color_clear >> 24) & 0xFF) / 255.0f;
    
    pgraph_mtl_clear(r, rgba[0], rgba[1], rgba[2], rgba[3]);
}

void pgraph_mtl_draw_begin(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_bind_textures(d);
    pgraph_mtl_bind_vertex_data(d);
    pgraph_mtl_begin_command_buffer(r);
}

void pgraph_mtl_draw_end(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    uint32_t vertex_count = 0;
    bool is_indexed = false;
    
    if (pg->inline_elements_length > 0) {
        vertex_count = pg->inline_elements_length;
        is_indexed = true;
    } else if (pg->inline_buffer_length > 0) {
        vertex_count = pg->inline_buffer_length;
    } else if (pg->draw_arrays_length > 0) {
        vertex_count = pg->draw_arrays_max_count;
    }
    
    if (vertex_count > 0) {
        pgraph_mtl_draw(r, is_indexed, 0, vertex_count);
    }
    
    pgraph_mtl_end_command_buffer(r);
    pgraph_mtl_submit_command_buffer(r);
}

void pgraph_mtl_flush_draw(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_flush(r);
    
    if (r->command_buffer && r->render_encoder) {
        pgraph_mtl_end_command_buffer(r);
    }
    
    if (r->command_buffer) {
        pgraph_mtl_submit_command_buffer(r);
    }
}

void pgraph_mtl_surface_update_callback(NV2AState *d, bool upload, bool color_write, bool zeta_write)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_surface_update_from_vram(d, upload, color_write, zeta_write);
}

void pgraph_mtl_surface_flush(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_surface_update(r);
    
    if (r->surface_color || r->surface_zeta) {
        pgraph_mtl_surface_update_callback(d, true, true, true);
    }
}

void pgraph_mtl_get_report(NV2AState *d, uint32_t parameter)
{
    PGRAPHState *pg = &d->pgraph;
    (void)pg;
    pgraph_write_zpass_pixel_cnt_report(d, parameter, 0);
}

void pgraph_mtl_image_blit_wrapper(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    pgraph_mtl_image_blit(pg->mtl_renderer_state);
}

void pgraph_mtl_set_surface_scale_factor(NV2AState *d, unsigned int scale)
{
    PGRAPHState *pg = &d->pgraph;
    pg->surface_scale_factor = scale;
}

unsigned int pgraph_mtl_get_surface_scale_factor(NV2AState *d)
{
    return d->pgraph.surface_scale_factor;
}

int pgraph_mtl_get_framebuffer_surface(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r || !r->surface_color) {
        return 0;
    }
    
    return 1;
}

void pgraph_mtl_flip_stall(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_flush_draw(d);
    pgraph_mtl_display_present(r);
}

void pgraph_mtl_process_pending(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    
    if (qatomic_read(&pg->sync_pending)) {
        qatomic_set(&pg->sync_pending, false);
        qemu_event_set(&pg->sync_complete);
    }
    if (qatomic_read(&pg->flush_pending)) {
        qatomic_set(&pg->flush_pending, false);
        qemu_event_set(&pg->flush_complete);
    }
}

void pgraph_mtl_process_pending_reports(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_download_reports(r);
}

void pgraph_mtl_pre_savevm_trigger(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_flush(r);
    pgraph_mtl_submit(r);
}

void pgraph_mtl_pre_savevm_wait(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_wait_idle(r);
}

void pgraph_mtl_pre_shutdown_trigger(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_flush(r);
    pgraph_mtl_submit(r);
}

void pgraph_mtl_pre_shutdown_wait(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_wait_idle(r);
}

void pgraph_mtl_bind_textures(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    for (int i = 0; i < NV2A_MAX_TEXTURES; i++) {
        bool enabled = pgraph_is_texture_enabled(pg, i);
        
        if (!enabled) {
            continue;
        }
        
        TextureShape state = pgraph_get_texture_shape(pg, i);
        hwaddr texture_vram_offset = pgraph_get_texture_phys_addr(pg, i);
        size_t length = pgraph_get_texture_length(pg, &state);
        
        if (texture_vram_offset >= memory_region_size(d->vram)) {
            continue;
        }
        
        if ((texture_vram_offset + length) > memory_region_size(d->vram)) {
            length = memory_region_size(d->vram) - texture_vram_offset;
        }
        
        uint8_t *texture_data = d->vram_ptr + texture_vram_offset;
        
        uint8_t *palette_data = NULL;
        size_t palette_length = 0;
        hwaddr palette_vram_offset = pgraph_get_texture_palette_phys_addr_length(pg, i, &palette_length);
        if (palette_vram_offset < memory_region_size(d->vram)) {
            palette_data = d->vram_ptr + palette_vram_offset;
        }
        
        pgraph_mtl_setup_texture_stage(r, i);
        
        pgraph_mtl_upload_texture_data(r, i, texture_data, state.width, state.height);
    }
}

void pgraph_mtl_bind_vertex_data(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    hwaddr dma_a = pg->dma_vertex_a;
    hwaddr dma_b = pg->dma_vertex_b;
    
    if (dma_a >= memory_region_size(d->vram)) {
        dma_a = 0;
    }
    if (dma_b >= memory_region_size(d->vram)) {
        dma_b = 0;
    }
    
    if (pg->inline_buffer_length > 0) {
        uint32_t *inline_data = pg->inline_array;
        size_t inline_size = pg->inline_buffer_length * sizeof(uint32_t);
        pgraph_mtl_update_vertex_buffer_from_data(r, inline_data, inline_size, 0);
    }
    
    if (dma_a > 0) {
        size_t max_size = memory_region_size(d->vram) - dma_a;
        size_t copy_size = MAX(max_size, 4 * 1024 * 1024);
        pgraph_mtl_update_vertex_buffer_from_data(r, d->vram_ptr + dma_a, copy_size, 0);
    }
}

static PGRAPHRenderer pgraph_mtl_renderer = {
    .type = CONFIG_DISPLAY_RENDERER_METAL,
    .name = "Metal",
    .ops = {
        .init = pgraph_mtl_init,
        .early_context_init = NULL,
        .finalize = pgraph_mtl_finalize,
        .clear_report_value = pgraph_mtl_clear_report_value,
        .clear_surface = pgraph_mtl_clear_surface,
        .draw_begin = pgraph_mtl_draw_begin,
        .draw_end = pgraph_mtl_draw_end,
        .flip_stall = pgraph_mtl_flip_stall,
        .flush_draw = pgraph_mtl_flush_draw,
        .get_report = pgraph_mtl_get_report,
        .image_blit = pgraph_mtl_image_blit_wrapper,
        .pre_savevm_trigger = pgraph_mtl_pre_savevm_trigger,
        .pre_savevm_wait = pgraph_mtl_pre_savevm_wait,
        .pre_shutdown_trigger = pgraph_mtl_pre_shutdown_trigger,
        .pre_shutdown_wait = pgraph_mtl_pre_shutdown_wait,
        .process_pending = pgraph_mtl_process_pending,
        .process_pending_reports = pgraph_mtl_process_pending_reports,
        .surface_flush = pgraph_mtl_surface_flush,
        .surface_update = pgraph_mtl_surface_update_callback,
        .set_surface_scale_factor = pgraph_mtl_set_surface_scale_factor,
        .get_surface_scale_factor = pgraph_mtl_get_surface_scale_factor,
        .get_framebuffer_surface = pgraph_mtl_get_framebuffer_surface,
        .get_gpu_properties = pgraph_mtl_get_gpu_properties,
    }
};

static void __attribute__((constructor)) register_renderer(void)
{
    pgraph_renderer_register(&pgraph_mtl_renderer);
}

#endif

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
#include <math.h>
#include "qemu/osdep.h"
#include "qemu/main-loop.h"
#include "hw/display/vga_int.h"
#include "hw/xbox/nv2a/pgraph/pgraph.h"
#include "hw/xbox/nv2a/pgraph/psh_regs.h"
#include "hw/xbox/nv2a/pgraph/swizzle.h"
#include "hw/xbox/nv2a/pgraph/util.h"
#include "ui/xemu-settings.h"
#include "nv2a_vsh_disassembler.h"
#include "nv2a_vsh_emulator.h"
#include "nv2a_vsh_emulator_execution_state.h"

typedef struct MTLQueryReport {
    bool clear;
    uint32_t parameter;
    uint32_t query_count;
} MTLQueryReport;

static void pgraph_mtl_update_viewport(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    unsigned int width = pg->surface_binding_dim.width;
    unsigned int height = pg->surface_binding_dim.height;

    if (!r) {
        return;
    }

    if (width == 0 || height == 0) {
        if (pg->surface_shape.clip_width && pg->surface_shape.clip_height) {
            width = pg->surface_shape.clip_width;
            height = pg->surface_shape.clip_height;
        } else if (pg->surface_shape.log_width && pg->surface_shape.log_height) {
            width = 1u << pg->surface_shape.log_width;
            height = 1u << pg->surface_shape.log_height;
        }
    }

    if (width == 0 || height == 0) {
        width = 640;
        height = 480;
    }

    pgraph_apply_scaling_factor(pg, &width, &height);
    r->viewport_width = width;
    r->viewport_height = height;
}

#define MTL_PRIM_POINT 0u
#define MTL_PRIM_LINE 1u
#define MTL_PRIM_TRIANGLE 3u

static void pgraph_mtl_vertex_init(MTLVertex *v)
{
    memset(v, 0, sizeof(*v));
    v->position[3] = 1.0f;
    v->diffuse[0] = 1.0f;
    v->diffuse[1] = 1.0f;
    v->diffuse[2] = 1.0f;
    v->diffuse[3] = 1.0f;
    v->specular[3] = 1.0f;
    v->texcoord0[3] = 1.0f;
    v->texcoord1[3] = 1.0f;
    v->texcoord2[3] = 1.0f;
    v->texcoord3[3] = 1.0f;
    v->fog[0] = 1.0f;
    v->normal[2] = 1.0f;
    v->normal[3] = 1.0f;
}

static void pgraph_mtl_decode_attribute(VertexAttribute *attr,
                                        const uint8_t *data, float out[4])
{
    VertexAttribute tmp = *attr;

    pgraph_update_inline_value(&tmp, data);
    memcpy(out, tmp.inline_value, sizeof(tmp.inline_value));
}

static void pgraph_mtl_assign_vertex(MTLVertex *v,
                                     float attrs[NV2A_VERTEXSHADER_ATTRIBUTES][4])
{
    memcpy(v->position, attrs[0], sizeof(v->position));
    memcpy(v->normal, attrs[2], sizeof(v->normal));
    memcpy(v->diffuse, attrs[3], sizeof(v->diffuse));
    memcpy(v->specular, attrs[4], sizeof(v->specular));
    memcpy(v->texcoord0, attrs[9], sizeof(v->texcoord0));
    memcpy(v->texcoord1, attrs[10], sizeof(v->texcoord1));
    memcpy(v->texcoord2, attrs[11], sizeof(v->texcoord2));
    memcpy(v->texcoord3, attrs[12], sizeof(v->texcoord3));
    v->fog[0] = attrs[5][0];

    if (v->position[3] == 0.0f) {
        v->position[3] = 1.0f;
    }
}

static float pgraph_mtl_clamp_away_zero_inf(float t)
{
    const union { uint32_t i; float f; } min_pos = { .i = 0x1F800000 };
    const union { uint32_t i; float f; } max_pos = { .i = 0x5F800000 };
    const union { uint32_t i; float f; } min_neg = { .i = 0xDF800000 };
    const union { uint32_t i; float f; } max_neg = { .i = 0x9F800000 };
    union { uint32_t i; float f; } bits = { .f = t };

    if (t > 0.0f || bits.i == 0) {
        return MIN(MAX(t, min_pos.f), max_pos.f);
    }

    return MIN(MAX(t, min_neg.f), max_neg.f);
}

static float pgraph_mtl_round_screen_coord(float pos)
{
    return truncf(pos * 16.0f) / 16.0f;
}

static void pgraph_mtl_mul_vec4_mat4(const float in[4],
                                     float mat[4][4], float out[4])
{
    for (int j = 0; j < 4; j++) {
        out[j] = in[0] * mat[0][j] + in[1] * mat[1][j] +
                 in[2] * mat[2][j] + in[3] * mat[3][j];
    }
}

static void pgraph_mtl_get_clip_range(PGRAPHState *pg, float clip_range[4])
{
    float zmax;

    switch (pg->surface_shape.zeta_format) {
    case NV097_SET_SURFACE_FORMAT_ZETA_Z16:
        zmax = pg->surface_shape.z_format ? f16_max : (float)0xFFFF;
        break;
    case NV097_SET_SURFACE_FORMAT_ZETA_Z24S8:
    default:
        zmax = pg->surface_shape.z_format ? f24_max : (float)0xFFFFFF;
        break;
    }

    clip_range[0] = 0.0f;
    clip_range[1] = zmax;
    uint32_t zclip_min = pgraph_reg_r(pg, NV_PGRAPH_ZCLIPMIN);
    uint32_t zclip_max = pgraph_reg_r(pg, NV_PGRAPH_ZCLIPMAX);

    clip_range[2] = *(float *)&zclip_min;
    clip_range[3] = *(float *)&zclip_max;
}

static bool pgraph_mtl_run_fixed_function_vsh(PGRAPHState *pg,
                                              float attrs[16][4], MTLVertex *v)
{
    if (GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CSV0_D), NV_PGRAPH_CSV0_D_MODE) != 0) {
        return false;
    }

    float composite_mat[4][4];
    float clip_range[4];
    unsigned int aa_width = 1;
    unsigned int aa_height = 1;
    float surface_size[2];
    float pos[4];
    float out[4];

    for (int i = 0; i < 4; i++) {
        memcpy(composite_mat[i], pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0 + i],
               sizeof(composite_mat[i]));
    }

    pgraph_apply_anti_aliasing_factor(pg, &aa_width, &aa_height);
    surface_size[0] = (float)pg->surface_binding_dim.width / aa_width;
    surface_size[1] = (float)pg->surface_binding_dim.height / aa_height;
    pgraph_mtl_get_clip_range(pg, clip_range);

    memcpy(pos, attrs[0], sizeof(pos));
    pgraph_mtl_mul_vec4_mat4(pos, composite_mat, out);

    out[3] = pgraph_mtl_clamp_away_zero_inf(out[3]);
    out[0] /= out[3];
    out[1] /= out[3];
    out[0] += pg->vsh_constants[NV_IGRAPH_XF_XFCTX_VPOFF][0];
    out[1] += pg->vsh_constants[NV_IGRAPH_XF_XFCTX_VPOFF][1];
    out[0] = pgraph_mtl_round_screen_coord(out[0]);
    out[1] = pgraph_mtl_round_screen_coord(out[1]);
    out[2] = out[2] / out[3];

    v->position[0] = (2.0f * out[0] - surface_size[0]) / surface_size[0] * out[3];
    v->position[1] = (2.0f * out[1] - surface_size[1]) / surface_size[1] * out[3];
    v->position[2] = out[2] / clip_range[1];
    v->position[3] = out[3];

    memcpy(v->diffuse, attrs[3], sizeof(v->diffuse));
    v->diffuse[0] = isnan(v->diffuse[0]) ? 1.0f : CLAMP(v->diffuse[0], 0.0f, 1.0f);
    v->diffuse[1] = isnan(v->diffuse[1]) ? 1.0f : CLAMP(v->diffuse[1], 0.0f, 1.0f);
    v->diffuse[2] = isnan(v->diffuse[2]) ? 1.0f : CLAMP(v->diffuse[2], 0.0f, 1.0f);
    v->diffuse[3] = isnan(v->diffuse[3]) ? 1.0f : CLAMP(v->diffuse[3], 0.0f, 1.0f);
    memcpy(v->specular, attrs[4], sizeof(v->specular));
    memcpy(v->normal, attrs[2], sizeof(v->normal));
    memcpy(v->texcoord0, attrs[9], sizeof(v->texcoord0));
    memcpy(v->texcoord1, attrs[10], sizeof(v->texcoord1));
    memcpy(v->texcoord2, attrs[11], sizeof(v->texcoord2));
    memcpy(v->texcoord3, attrs[12], sizeof(v->texcoord3));
    v->fog[0] = attrs[5][0];
    return true;
}

static bool pgraph_mtl_prepare_vertex_program(PGRAPHState *pg,
                                              Nv2aVshProgram *program)
{
    if (GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CSV0_D),
                 NV_PGRAPH_CSV0_D_MODE) != 2) {
        return false;
    }

    unsigned int program_start = GET_MASK(
        pgraph_reg_r(pg, NV_PGRAPH_CSV0_C),
        NV_PGRAPH_CSV0_C_CHEOPS_PROGRAM_START);
    if (program_start >= NV2A_MAX_TRANSFORM_PROGRAM_LENGTH) {
        return false;
    }

    return nv2a_vsh_parse_program(
               program, pg->program_data[program_start],
               NV2A_MAX_TRANSFORM_PROGRAM_LENGTH - program_start) ==
           NV2AVPR_SUCCESS;
}

static bool pgraph_mtl_run_programmable_vsh(PGRAPHState *pg,
                                            const Nv2aVshProgram *program,
                                            float attrs[16][4], MTLVertex *v)
{
    Nv2aVshCPUFullExecutionState state_linkage;
    Nv2aVshExecutionState state;

    if (!program) {
        return false;
    }

    state = nv2a_vsh_emu_initialize_full_execution_state(&state_linkage);
    memcpy(state_linkage.input_regs, attrs, sizeof(state_linkage.input_regs));
    memcpy(state_linkage.context_regs, pg->vsh_constants,
           sizeof(state_linkage.context_regs));
    nv2a_vsh_emu_execute(&state, program);

    memcpy(v->position,
           &state_linkage.output_regs[NV2AOR_POS * 4],
           sizeof(v->position));
    memcpy(v->diffuse,
           &state_linkage.output_regs[NV2AOR_DIFFUSE * 4],
           sizeof(v->diffuse));
    memcpy(v->specular,
           &state_linkage.output_regs[NV2AOR_SPECULAR * 4],
           sizeof(v->specular));
    memcpy(v->fog,
           &state_linkage.output_regs[NV2AOR_FOG_COORD * 4],
           sizeof(v->fog));
    memcpy(v->texcoord0,
           &state_linkage.output_regs[NV2AOR_TEX0 * 4],
           sizeof(v->texcoord0));
    memcpy(v->texcoord1,
           &state_linkage.output_regs[NV2AOR_TEX1 * 4],
           sizeof(v->texcoord1));
    memcpy(v->texcoord2,
           &state_linkage.output_regs[NV2AOR_TEX2 * 4],
           sizeof(v->texcoord2));
    memcpy(v->texcoord3,
           &state_linkage.output_regs[NV2AOR_TEX3 * 4],
           sizeof(v->texcoord3));

    if (v->position[3] == 0.0f) {
        v->position[3] = 1.0f;
    }
    return true;
}

static void pgraph_mtl_decode_vertex_from_dma(NV2AState *d, unsigned int index,
                                              const Nv2aVshProgram *program,
                                              MTLVertex *v)
{
    PGRAPHState *pg = &d->pgraph;
    float attrs[NV2A_VERTEXSHADER_ATTRIBUTES][4];

    memset(attrs, 0, sizeof(attrs));
    pgraph_mtl_vertex_init(v);

    for (int i = 0; i < NV2A_VERTEXSHADER_ATTRIBUTES; i++) {
        VertexAttribute *attr = &pg->vertex_attributes[i];

        memcpy(attrs[i], attr->inline_value, sizeof(attr->inline_value));
        if (!attr->count || attr->stride == 0) {
            continue;
        }

        hwaddr dma_len;
        uint8_t *attr_data = (uint8_t *)nv_dma_map(
            d, attr->dma_select ? pg->dma_vertex_b : pg->dma_vertex_a,
            &dma_len);

        if (!attr_data || attr->offset >= dma_len) {
            continue;
        }

        hwaddr offset = attr->offset + (hwaddr)index * attr->stride;
        size_t size = attr->size * MAX(1u, attr->count);
        if (offset + size > dma_len) {
            continue;
        }

        pgraph_mtl_decode_attribute(attr, attr_data + offset, attrs[i]);
    }

    if (!pgraph_mtl_run_programmable_vsh(pg, program, attrs, v) &&
        !pgraph_mtl_run_fixed_function_vsh(pg, attrs, v)) {
        pgraph_mtl_assign_vertex(v, attrs);
    }
}

static void pgraph_mtl_compute_inline_array_layout(PGRAPHState *pg,
                                                   unsigned int *vertex_size,
                                                   unsigned int offsets[16])
{
    unsigned int offset = 0;

    memset(offsets, 0, sizeof(unsigned int) * NV2A_VERTEXSHADER_ATTRIBUTES);
    for (int i = 0; i < NV2A_VERTEXSHADER_ATTRIBUTES; i++) {
        VertexAttribute *attr = &pg->vertex_attributes[i];
        if (!attr->count) {
            continue;
        }

        offset = ROUND_UP(offset, attr->size);
        offsets[i] = offset;
        offset += attr->size * attr->count;
        offset = ROUND_UP(offset, attr->size);
    }

    *vertex_size = offset;
}

static void pgraph_mtl_decode_vertex_from_inline_array(NV2AState *d,
                                                       unsigned int index,
                                                       const Nv2aVshProgram *program,
                                                       MTLVertex *v)
{
    PGRAPHState *pg = &d->pgraph;
    float attrs[NV2A_VERTEXSHADER_ATTRIBUTES][4];
    unsigned int vertex_size;
    unsigned int offsets[16];
    const uint8_t *base;

    memset(attrs, 0, sizeof(attrs));
    pgraph_mtl_vertex_init(v);
    pgraph_mtl_compute_inline_array_layout(pg, &vertex_size, offsets);
    base = (const uint8_t *)pg->inline_array + index * vertex_size;

    for (int i = 0; i < NV2A_VERTEXSHADER_ATTRIBUTES; i++) {
        VertexAttribute *attr = &pg->vertex_attributes[i];

        memcpy(attrs[i], attr->inline_value, sizeof(attr->inline_value));
        if (!attr->count) {
            continue;
        }

        pgraph_mtl_decode_attribute(attr, base + offsets[i], attrs[i]);
    }

    if (!pgraph_mtl_run_programmable_vsh(pg, program, attrs, v) &&
        !pgraph_mtl_run_fixed_function_vsh(pg, attrs, v)) {
        pgraph_mtl_assign_vertex(v, attrs);
    }
}

static void pgraph_mtl_decode_vertex_from_inline_buffer(NV2AState *d,
                                                        unsigned int index,
                                                        const Nv2aVshProgram *program,
                                                        MTLVertex *v)
{
    PGRAPHState *pg = &d->pgraph;
    float attrs[NV2A_VERTEXSHADER_ATTRIBUTES][4];

    memset(attrs, 0, sizeof(attrs));
    pgraph_mtl_vertex_init(v);

    for (int i = 0; i < NV2A_VERTEXSHADER_ATTRIBUTES; i++) {
        memcpy(attrs[i], pg->vertex_attributes[i].inline_value,
               sizeof(pg->vertex_attributes[i].inline_value));
    }

    if (pg->vertex_attributes[0].inline_buffer_populated) {
        memcpy(attrs[0],
               &pg->vertex_attributes[0].inline_buffer[index * 4],
               sizeof(attrs[0]));
    }
    if (pg->vertex_attributes[2].inline_buffer_populated) {
        memcpy(attrs[2],
               &pg->vertex_attributes[2].inline_buffer[index * 4],
               sizeof(attrs[2]));
    }
    if (pg->vertex_attributes[3].inline_buffer_populated) {
        memcpy(attrs[3],
               &pg->vertex_attributes[3].inline_buffer[index * 4],
               sizeof(attrs[3]));
    }
    if (pg->vertex_attributes[9].inline_buffer_populated) {
        memcpy(attrs[9],
               &pg->vertex_attributes[9].inline_buffer[index * 4],
               sizeof(attrs[9]));
    }

    if (!pgraph_mtl_run_programmable_vsh(pg, program, attrs, v) &&
        !pgraph_mtl_run_fixed_function_vsh(pg, attrs, v)) {
        pgraph_mtl_assign_vertex(v, attrs);
    }
}

static void pgraph_mtl_append_line(GArray *out, const MTLVertex *a,
                                   const MTLVertex *b)
{
    g_array_append_vals(out, a, 1);
    g_array_append_vals(out, b, 1);
}

static void pgraph_mtl_append_triangle(GArray *out, const MTLVertex *a,
                                       const MTLVertex *b,
                                       const MTLVertex *c)
{
    g_array_append_vals(out, a, 1);
    g_array_append_vals(out, b, 1);
    g_array_append_vals(out, c, 1);
}

static void pgraph_mtl_expand_vertices(PGRAPHState *pg, const MTLVertex *src,
                                       unsigned int count, GArray *out,
                                       uint32_t *primitive_type)
{
    uint32_t setup_raster = pgraph_reg_r(pg, NV_PGRAPH_SETUPRASTER);
    enum ShaderPolygonMode polygon_mode =
        GET_MASK(setup_raster, NV_PGRAPH_SETUPRASTER_FRONTFACEMODE);

    switch (pg->primitive_mode) {
    case PRIM_TYPE_POINTS:
        *primitive_type = MTL_PRIM_POINT;
        g_array_append_vals(out, src, count);
        return;
    case PRIM_TYPE_LINES:
        if (polygon_mode == POLY_MODE_POINT) {
            *primitive_type = MTL_PRIM_POINT;
            g_array_append_vals(out, src, count);
            return;
        }
        *primitive_type = MTL_PRIM_LINE;
        g_array_append_vals(out, src, count - (count % 2));
        return;
    case PRIM_TYPE_LINE_STRIP:
        if (polygon_mode == POLY_MODE_POINT) {
            *primitive_type = MTL_PRIM_POINT;
            g_array_append_vals(out, src, count);
            return;
        }
        *primitive_type = MTL_PRIM_LINE;
        for (unsigned int i = 0; i + 1 < count; i++) {
            pgraph_mtl_append_line(out, &src[i], &src[i + 1]);
        }
        return;
    case PRIM_TYPE_LINE_LOOP:
        if (polygon_mode == POLY_MODE_POINT) {
            *primitive_type = MTL_PRIM_POINT;
            g_array_append_vals(out, src, count);
            return;
        }
        *primitive_type = MTL_PRIM_LINE;
        for (unsigned int i = 0; i + 1 < count; i++) {
            pgraph_mtl_append_line(out, &src[i], &src[i + 1]);
        }
        if (count > 2) {
            pgraph_mtl_append_line(out, &src[count - 1], &src[0]);
        }
        return;
    case PRIM_TYPE_TRIANGLES:
        break;
    case PRIM_TYPE_TRIANGLE_STRIP:
        *primitive_type = polygon_mode == POLY_MODE_POINT ? MTL_PRIM_POINT :
                          polygon_mode == POLY_MODE_LINE ? MTL_PRIM_LINE :
                          MTL_PRIM_TRIANGLE;
        for (unsigned int i = 0; i + 2 < count; i++) {
            if (polygon_mode == POLY_MODE_POINT) {
                MTLVertex tri[] = { src[i], src[i + 1], src[i + 2] };
                g_array_append_vals(out, tri, 3);
            } else if (polygon_mode == POLY_MODE_LINE) {
                pgraph_mtl_append_line(out, &src[i], &src[i + 1]);
                pgraph_mtl_append_line(out, &src[i + 1], &src[i + 2]);
                pgraph_mtl_append_line(out, &src[i + 2], &src[i]);
            } else if (i & 1) {
                pgraph_mtl_append_triangle(out, &src[i + 1], &src[i],
                                           &src[i + 2]);
            } else {
                pgraph_mtl_append_triangle(out, &src[i], &src[i + 1],
                                           &src[i + 2]);
            }
        }
        return;
    case PRIM_TYPE_TRIANGLE_FAN:
    case PRIM_TYPE_POLYGON:
        if (polygon_mode == POLY_MODE_POINT) {
            *primitive_type = MTL_PRIM_POINT;
            g_array_append_vals(out, src, count);
            return;
        }
        if (polygon_mode == POLY_MODE_LINE) {
            *primitive_type = MTL_PRIM_LINE;
            for (unsigned int i = 0; i + 1 < count; i++) {
                pgraph_mtl_append_line(out, &src[i], &src[i + 1]);
            }
            if (count > 2) {
                pgraph_mtl_append_line(out, &src[count - 1], &src[0]);
            }
            return;
        }
        *primitive_type = MTL_PRIM_TRIANGLE;
        for (unsigned int i = 1; i + 1 < count; i++) {
            pgraph_mtl_append_triangle(out, &src[0], &src[i], &src[i + 1]);
        }
        return;
    case PRIM_TYPE_QUADS:
        if (polygon_mode == POLY_MODE_POINT) {
            *primitive_type = MTL_PRIM_POINT;
            g_array_append_vals(out, src, count);
            return;
        }
        *primitive_type = polygon_mode == POLY_MODE_LINE ? MTL_PRIM_LINE :
                          MTL_PRIM_TRIANGLE;
        for (unsigned int i = 0; i + 3 < count; i += 4) {
            if (polygon_mode == POLY_MODE_LINE) {
                pgraph_mtl_append_line(out, &src[i], &src[i + 1]);
                pgraph_mtl_append_line(out, &src[i + 1], &src[i + 2]);
                pgraph_mtl_append_line(out, &src[i + 2], &src[i + 3]);
                pgraph_mtl_append_line(out, &src[i + 3], &src[i]);
            } else {
                pgraph_mtl_append_triangle(out, &src[i], &src[i + 1],
                                           &src[i + 2]);
                pgraph_mtl_append_triangle(out, &src[i], &src[i + 2],
                                           &src[i + 3]);
            }
        }
        return;
    case PRIM_TYPE_QUAD_STRIP:
        if (polygon_mode == POLY_MODE_POINT) {
            *primitive_type = MTL_PRIM_POINT;
            g_array_append_vals(out, src, count);
            return;
        }
        *primitive_type = polygon_mode == POLY_MODE_LINE ? MTL_PRIM_LINE :
                          MTL_PRIM_TRIANGLE;
        for (unsigned int i = 0; i + 3 < count; i += 2) {
            if (polygon_mode == POLY_MODE_LINE) {
                pgraph_mtl_append_line(out, &src[i], &src[i + 1]);
                pgraph_mtl_append_line(out, &src[i + 1], &src[i + 3]);
                pgraph_mtl_append_line(out, &src[i + 3], &src[i + 2]);
                pgraph_mtl_append_line(out, &src[i + 2], &src[i]);
            } else {
                pgraph_mtl_append_triangle(out, &src[i], &src[i + 1],
                                           &src[i + 2]);
                pgraph_mtl_append_triangle(out, &src[i + 1], &src[i + 3],
                                           &src[i + 2]);
            }
        }
        return;
    default:
        return;
    }

    if (polygon_mode == POLY_MODE_POINT) {
        *primitive_type = MTL_PRIM_POINT;
        g_array_append_vals(out, src, count);
        return;
    }

    if (polygon_mode == POLY_MODE_LINE) {
        *primitive_type = MTL_PRIM_LINE;
        for (unsigned int i = 0; i + 2 < count; i += 3) {
            pgraph_mtl_append_line(out, &src[i], &src[i + 1]);
            pgraph_mtl_append_line(out, &src[i + 1], &src[i + 2]);
            pgraph_mtl_append_line(out, &src[i + 2], &src[i]);
        }
        return;
    }

    *primitive_type = MTL_PRIM_TRIANGLE;
    g_array_append_vals(out, src, count - (count % 3));
}

static unsigned int pgraph_mtl_surface_color_bytes_per_pixel(
    unsigned int color_format)
{
    switch (color_format) {
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_B8:
        return 1;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5:
        return 2;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8:
    default:
        return 4;
    }
}

static void pgraph_mtl_update_display_size(NV2AState *d);

static unsigned int pgraph_mtl_surface_zeta_bytes_per_pixel(
    unsigned int zeta_format)
{
    switch (zeta_format) {
    case NV097_SET_SURFACE_FORMAT_ZETA_Z16:
        return 2;
    case NV097_SET_SURFACE_FORMAT_ZETA_Z24S8:
    default:
        return 4;
    }
}

static void pgraph_mtl_reload_surface_scale_factor(PGRAPHState *pg)
{
    int factor = g_config.display.quality.surface_scale;

    pg->surface_scale_factor = MAX(factor, 1);
}

static uint8_t *pgraph_mtl_surface_convert_to_bgra8(const uint8_t *src,
                                                    unsigned int width,
                                                    unsigned int height,
                                                    unsigned int src_pitch,
                                                    unsigned int color_format)
{
    uint8_t *dst = g_malloc(width * height * 4);

    for (unsigned int y = 0; y < height; y++) {
        const uint8_t *in = src + y * src_pitch;
        uint8_t *out = dst + y * width * 4;

        for (unsigned int x = 0; x < width; x++) {
            uint8_t b = 0;
            uint8_t g = 0;
            uint8_t r = 0;
            uint8_t a = 0xff;

            switch (color_format) {
            case NV097_SET_SURFACE_FORMAT_COLOR_LE_B8:
                b = g = r = in[x];
                break;
            case NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8:
                b = in[x * 2 + 0];
                g = in[x * 2 + 1];
                r = 0;
                break;
            case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5:
            case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5: {
                uint16_t v = ((const uint16_t *)in)[x];
                b = ((v >> 0) & 0x1f) * 255 / 31;
                g = ((v >> 5) & 0x1f) * 255 / 31;
                r = ((v >> 10) & 0x1f) * 255 / 31;
                break;
            }
            case NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5: {
                uint16_t v = ((const uint16_t *)in)[x];
                b = ((v >> 0) & 0x1f) * 255 / 31;
                g = ((v >> 5) & 0x3f) * 255 / 63;
                r = ((v >> 11) & 0x1f) * 255 / 31;
                break;
            }
            case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8:
            case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8:
            case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8:
            case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8:
            case NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8:
            default:
                b = in[x * 4 + 0];
                g = in[x * 4 + 1];
                r = in[x * 4 + 2];
                a = color_format == NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8 ?
                    in[x * 4 + 3] : 0xff;
                break;
            }

            out[x * 4 + 0] = b;
            out[x * 4 + 1] = g;
            out[x * 4 + 2] = r;
            out[x * 4 + 3] = a;
        }
    }

    return dst;
}

static bool pgraph_mtl_texture_stage_usable(PGRAPHState *pg,
                                            unsigned int stage)
{
    uint32_t fmt;
    unsigned int color_format;
    unsigned int dimensionality;
    unsigned int levels;

    if (stage >= NV2A_MAX_TEXTURES) {
        return false;
    }

    if (!pgraph_is_texture_enabled(pg, stage) ||
        !pgraph_is_texture_stage_active(pg, stage)) {
        return false;
    }

    fmt = pgraph_reg_r(pg, NV_PGRAPH_TEXFMT0 + stage * 4);
    color_format = GET_MASK(fmt, NV_PGRAPH_TEXFMT0_COLOR);
    dimensionality = GET_MASK(fmt, NV_PGRAPH_TEXFMT0_DIMENSIONALITY);
    levels = GET_MASK(fmt, NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS);

    if (color_format >= ARRAY_SIZE(kelvin_color_format_info_map)) {
        return false;
    }

    if (dimensionality < 2 || dimensionality > 3) {
        return false;
    }

    if (!kelvin_color_format_info_map[color_format].linear && levels == 0) {
        return false;
    }

    return true;
}

static uint32_t pgraph_mtl_get_color_key_mask_for_texture(PGRAPHState *pg,
                                                          unsigned int i)
{
    uint32_t fmt = pgraph_reg_r(pg, NV_PGRAPH_TEXFMT0 + i * 4);
    unsigned int color_format = GET_MASK(fmt, NV_PGRAPH_TEXFMT0_COLOR);

    switch (color_format) {
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5:
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8:
        return 0x00FFFFFF;
    default:
        return 0xFFFFFFFF;
    }
}

static void pgraph_mtl_surface_copy_expand_row(uint8_t *out, const uint8_t *in,
                                               unsigned int width,
                                               unsigned int bytes_per_pixel,
                                               unsigned int factor)
{
    for (unsigned int x = 0; x < width; x++) {
        for (unsigned int i = 0; i < factor; i++) {
            memcpy(out, in, bytes_per_pixel);
            out += bytes_per_pixel;
        }
        in += bytes_per_pixel;
    }
}

static void pgraph_mtl_surface_copy_expand(uint8_t *out, const uint8_t *in,
                                           unsigned int width,
                                           unsigned int height,
                                           unsigned int bytes_per_pixel,
                                           unsigned int factor)
{
    size_t out_pitch = width * bytes_per_pixel * factor;

    for (unsigned int y = 0; y < height; y++) {
        pgraph_mtl_surface_copy_expand_row(out, in, width, bytes_per_pixel,
                                           factor);
        const uint8_t *row_in = out;
        for (unsigned int i = 1; i < factor; i++) {
            out += out_pitch;
            memcpy(out, row_in, out_pitch);
        }
        in += width * bytes_per_pixel;
        out += out_pitch;
    }
}

static uint8_t *pgraph_mtl_convert_scanout_from_bpp(const uint8_t *src,
                                                    unsigned int width,
                                                    unsigned int height,
                                                    unsigned int src_pitch,
                                                    int bpp)
{
    uint8_t *dst = g_malloc(width * height * 4);

    for (unsigned int y = 0; y < height; y++) {
        const uint8_t *in = src + y * src_pitch;
        uint8_t *out = dst + y * width * 4;

        for (unsigned int x = 0; x < width; x++) {
            uint8_t b = 0;
            uint8_t g = 0;
            uint8_t r = 0;
            uint8_t a = 0xff;

            switch (bpp) {
            case 15: {
                uint16_t v = ((const uint16_t *)in)[x];
                b = ((v >> 0) & 0x1f) * 255 / 31;
                g = ((v >> 5) & 0x1f) * 255 / 31;
                r = ((v >> 10) & 0x1f) * 255 / 31;
                break;
            }
            case 16: {
                uint16_t v = ((const uint16_t *)in)[x];
                b = ((v >> 0) & 0x1f) * 255 / 31;
                g = ((v >> 5) & 0x3f) * 255 / 63;
                r = ((v >> 11) & 0x1f) * 255 / 31;
                break;
            }
            case 32:
                b = in[x * 4 + 0];
                g = in[x * 4 + 1];
                r = in[x * 4 + 2];
                a = in[x * 4 + 3];
                break;
            case 8:
            default:
                b = g = r = in[x];
                break;
            }

            out[x * 4 + 0] = b;
            out[x * 4 + 1] = g;
            out[x * 4 + 2] = r;
            out[x * 4 + 3] = a;
        }
    }

    return dst;
}

static void pgraph_mtl_surface_get_dimensions(PGRAPHState *pg,
                                              unsigned int *width,
                                              unsigned int *height)
{
    bool swizzle =
        (pg->surface_type == NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE);

    if (swizzle) {
        *width = 1 << pg->surface_shape.log_width;
        *height = 1 << pg->surface_shape.log_height;
    } else {
        *width = pg->surface_shape.clip_width;
        *height = pg->surface_shape.clip_height;
    }
}

static void pgraph_mtl_apply_pvideo_overlay(NV2AState *d, uint8_t *dst,
                                            unsigned int display_width,
                                            unsigned int display_height);

static void pgraph_mtl_display_surface_cache_entry_free(gpointer data)
{
    PGRAPHMTLDisplaySurfaceCacheEntry *entry = data;

    if (!entry) {
        return;
    }

    g_free(entry->data);
    g_free(entry);
}

static GPtrArray *pgraph_mtl_get_display_surface_cache(PGRAPHMTLState *r)
{
    if (!r->display_surface_cache) {
        r->display_surface_cache =
            g_ptr_array_new_with_free_func(
                pgraph_mtl_display_surface_cache_entry_free);
    }

    return r->display_surface_cache;
}

static PGRAPHMTLDisplaySurfaceCacheEntry *
pgraph_mtl_find_display_surface_cache_entry(PGRAPHMTLState *r, hwaddr addr)
{
    GPtrArray *cache = r->display_surface_cache;

    if (!cache) {
        return NULL;
    }

    for (guint i = 0; i < cache->len; i++) {
        PGRAPHMTLDisplaySurfaceCacheEntry *entry = g_ptr_array_index(cache, i);

        if (addr >= entry->vram_addr && addr < entry->vram_addr + entry->size) {
            return entry;
        }
    }

    return NULL;
}

static void pgraph_mtl_snapshot_current_surface(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    DMAObject dma;
    hwaddr vram_addr;
    hwaddr size;
    unsigned int width;
    unsigned int height;
    unsigned int bpp;
    size_t data_size;
    GPtrArray *cache;
    PGRAPHMTLDisplaySurfaceCacheEntry *entry;
    unsigned int evict_index = 0;
    uint32_t oldest_frame = UINT32_MAX;

    if (!r || !r->surface_color || !pg->dma_color ||
        pg->surface_binding_dim.width <= 0 || pg->surface_binding_dim.height <= 0) {
        return;
    }

    dma = nv_dma_load(d, pg->dma_color);
    if (dma.dma_class != NV_DMA_IN_MEMORY_CLASS) {
        return;
    }

    bpp = pgraph_mtl_surface_color_bytes_per_pixel(pg->surface_shape.color_format);
    pgraph_mtl_surface_get_dimensions(pg, &width, &height);
    pgraph_apply_anti_aliasing_factor(pg, &width, &height);
    if (pg->surface_type != NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE) {
        width += pg->surface_shape.clip_x;
        height += pg->surface_shape.clip_y;
    }
    pgraph_apply_scaling_factor(pg, &width, &height);
    width = MAX(width, 1u);
    height = MAX(height, 1u);
    vram_addr = dma.address + pg->surface_color.offset;
    size = (hwaddr)pg->surface_color.pitch * height;
    data_size = (size_t)width * height * 4;

    cache = pgraph_mtl_get_display_surface_cache(r);
    entry = pgraph_mtl_find_display_surface_cache_entry(r, vram_addr);

    if (!entry) {
        if (cache->len >= 8) {
            for (guint i = 0; i < cache->len; i++) {
                PGRAPHMTLDisplaySurfaceCacheEntry *candidate =
                    g_ptr_array_index(cache, i);

                if (candidate->frame_time < oldest_frame) {
                    oldest_frame = candidate->frame_time;
                    evict_index = i;
                }
            }
            g_ptr_array_remove_index(cache, evict_index);
        }

        entry = g_new0(PGRAPHMTLDisplaySurfaceCacheEntry, 1);
        g_ptr_array_add(cache, entry);
    }

    if (!entry->data || entry->tex_width != width || entry->tex_height != height) {
        g_free(entry->data);
        entry->data = g_malloc(data_size);
    }

    pgraph_mtl_sync_texture_for_cpu(r, r->surface_color);

    if (!pgraph_mtl_display_copy_texture(r->surface_color, entry->data,
                                         width * 4, width, height)) {
        return;
    }

    entry->vram_addr = vram_addr;
    entry->size = size;
    entry->pitch = pg->surface_color.pitch;
    entry->width = pg->surface_binding_dim.width;
    entry->height = pg->surface_binding_dim.height;
    entry->tex_width = width;
    entry->tex_height = height;
    entry->frame_time = pg->frame_time;

    (void)bpp;
}

static bool pgraph_mtl_update_display_from_surface(NV2AState *d,
                                                   unsigned int display_width,
                                                   unsigned int display_height)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    VGADisplayParams vga_display_params;
    hwaddr scanout_addr;
    PGRAPHMTLDisplaySurfaceCacheEntry *entry;
    uint8_t *src = NULL;
    uint8_t *dst = NULL;
    float line_offset_factor;
    bool ok = false;

    if (!r || !r->display_surface_cache) {
        return false;
    }

    d->vga.get_params(&d->vga, &vga_display_params);
    if (!vga_display_params.line_offset) {
        return false;
    }

    scanout_addr = d->pcrtc.start + vga_display_params.line_offset;
    entry = pgraph_mtl_find_display_surface_cache_entry(r, scanout_addr);
    if (!entry || !entry->data || !entry->pitch) {
        return false;
    }

    src = entry->data;

    dst = g_malloc((size_t)display_width * display_height * 4);
    line_offset_factor =
        (float)entry->pitch / (float)vga_display_params.line_offset;
    if (line_offset_factor <= 0.0f) {
        line_offset_factor = 1.0f;
    }

    for (unsigned int y = 0; y < display_height; y++) {
        unsigned int src_y = MIN(
            (unsigned int)(((float)(display_height - 1 - y)) /
                           line_offset_factor),
            entry->tex_height - 1);
        for (unsigned int x = 0; x < display_width; x++) {
            unsigned int src_x = MIN((unsigned int)((uint64_t)x * entry->tex_width /
                                                    MAX(display_width, 1u)),
                                     entry->tex_width - 1);
            memcpy(dst + ((size_t)y * display_width + x) * 4,
                   src + ((size_t)src_y * entry->tex_width + src_x) * 4,
                   4);
        }
    }

    pgraph_mtl_apply_pvideo_overlay(d, dst, display_width, display_height);

    ok = pgraph_mtl_display_upload(r, dst, display_width, display_height,
                                   display_width * 4);
    g_free(dst);
    return ok;
}

typedef struct PGRAPHMTLPvideoState {
    bool enabled;
    hwaddr base;
    hwaddr limit;
    hwaddr offset;
    unsigned int pitch;
    unsigned int format;
    unsigned int in_width;
    unsigned int in_height;
    unsigned int out_width;
    unsigned int out_height;
    unsigned int in_s;
    unsigned int in_t;
    float scale_x;
    float scale_y;
    unsigned int out_x;
    unsigned int out_y;
    bool color_key_enabled;
    uint32_t color_key;
} PGRAPHMTLPvideoState;

static float pgraph_mtl_pvideo_calculate_scale(unsigned int din_dout,
                                               unsigned int output_size)
{
    float calculated_in = din_dout * (output_size - 1);
    calculated_in = floorf(calculated_in / (1 << 20) + 0.5f);
    return (calculated_in + 1.0f) / output_size;
}

static PGRAPHMTLPvideoState pgraph_mtl_get_pvideo_state(PGRAPHState *pg)
{
    NV2AState *d = container_of(pg, NV2AState, pgraph);
    PGRAPHMTLPvideoState state;

    memset(&state, 0, sizeof(state));

    state.enabled =
        (d->pvideo.regs[NV_PVIDEO_BUFFER] & NV_PVIDEO_BUFFER_0_USE) &&
        d->pvideo.regs[NV_PVIDEO_SIZE_IN] != 0xFFFFFFFF;
    if (!state.enabled) {
        return state;
    }

    state.base = d->pvideo.regs[NV_PVIDEO_BASE];
    state.limit = d->pvideo.regs[NV_PVIDEO_LIMIT];
    state.offset = d->pvideo.regs[NV_PVIDEO_OFFSET];
    state.pitch = GET_MASK(d->pvideo.regs[NV_PVIDEO_FORMAT],
                           NV_PVIDEO_FORMAT_PITCH);
    state.format = GET_MASK(d->pvideo.regs[NV_PVIDEO_FORMAT],
                            NV_PVIDEO_FORMAT_COLOR);
    state.in_width = GET_MASK(d->pvideo.regs[NV_PVIDEO_SIZE_IN],
                              NV_PVIDEO_SIZE_IN_WIDTH);
    state.in_height = GET_MASK(d->pvideo.regs[NV_PVIDEO_SIZE_IN],
                               NV_PVIDEO_SIZE_IN_HEIGHT);
    state.out_width = GET_MASK(d->pvideo.regs[NV_PVIDEO_SIZE_OUT],
                               NV_PVIDEO_SIZE_OUT_WIDTH);
    state.out_height = GET_MASK(d->pvideo.regs[NV_PVIDEO_SIZE_OUT],
                                NV_PVIDEO_SIZE_OUT_HEIGHT);
    state.in_s = GET_MASK(d->pvideo.regs[NV_PVIDEO_POINT_IN],
                          NV_PVIDEO_POINT_IN_S);
    state.in_t = GET_MASK(d->pvideo.regs[NV_PVIDEO_POINT_IN],
                          NV_PVIDEO_POINT_IN_T);

    uint32_t ds_dx = d->pvideo.regs[NV_PVIDEO_DS_DX];
    uint32_t dt_dy = d->pvideo.regs[NV_PVIDEO_DT_DY];
    state.scale_x = ds_dx == NV_PVIDEO_DIN_DOUT_UNITY ?
        1.0f : pgraph_mtl_pvideo_calculate_scale(ds_dx, state.out_width);
    state.scale_y = dt_dy == NV_PVIDEO_DIN_DOUT_UNITY ?
        1.0f : pgraph_mtl_pvideo_calculate_scale(dt_dy, state.out_height);

    if (state.in_width > state.out_width) {
        state.in_width = floorf((float)state.out_width * state.scale_x + 0.5f);
    }
    if (state.in_height > state.out_height) {
        state.in_height = floorf((float)state.out_height * state.scale_y + 0.5f);
    }

    state.out_x = GET_MASK(d->pvideo.regs[NV_PVIDEO_POINT_OUT],
                           NV_PVIDEO_POINT_OUT_X);
    state.out_y = GET_MASK(d->pvideo.regs[NV_PVIDEO_POINT_OUT],
                           NV_PVIDEO_POINT_OUT_Y);
    state.color_key_enabled = GET_MASK(d->pvideo.regs[NV_PVIDEO_FORMAT],
                                       NV_PVIDEO_FORMAT_DISPLAY);
    state.color_key = d->pvideo.regs[NV_PVIDEO_COLOR_KEY] & 0xFFFFFF;

    if (state.offset + state.pitch * state.in_height > state.limit ||
        state.base + state.offset + state.pitch * state.in_height >
            memory_region_size(d->vram)) {
        state.enabled = false;
    }

    return state;
}

static void pgraph_mtl_apply_pvideo_overlay(NV2AState *d, uint8_t *dst,
                                            unsigned int display_width,
                                            unsigned int display_height)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLPvideoState pvideo = pgraph_mtl_get_pvideo_state(pg);

    if (!pvideo.enabled ||
        pvideo.format != NV_PVIDEO_FORMAT_COLOR_LE_CR8YB8CB8YA8) {
        return;
    }

    unsigned int out_x = pvideo.out_x;
    unsigned int out_y = pvideo.out_y;
    unsigned int out_width = pvideo.out_width;
    unsigned int out_height = pvideo.out_height;
    pgraph_apply_scaling_factor(pg, &out_x, &out_y);
    pgraph_apply_scaling_factor(pg, &out_width, &out_height);

    const uint8_t *src = d->vram_ptr + pvideo.base + pvideo.offset;
    uint8_t color_key_r = GET_MASK(pvideo.color_key, NV_PVIDEO_COLOR_KEY_RED);
    uint8_t color_key_g = GET_MASK(pvideo.color_key, NV_PVIDEO_COLOR_KEY_GREEN);
    uint8_t color_key_b = GET_MASK(pvideo.color_key, NV_PVIDEO_COLOR_KEY_BLUE);

    for (unsigned int y = 0; y < out_height; y++) {
        int dst_y = (int)display_height - 1 - ((int)out_y + (int)y);
        if (dst_y < 0 || dst_y >= (int)display_height) {
            continue;
        }

        float out_yf = (float)y * (1.0f / MAX(pg->surface_scale_factor, 1u));
        float src_v = pvideo.in_t / 8.0f + out_yf * pvideo.scale_y;
        unsigned int src_y = MIN((unsigned int)src_v, pvideo.in_height - 1);
        const uint8_t *line = src + src_y * pvideo.pitch;

        for (unsigned int x = 0; x < out_width; x++) {
            int dst_x = out_x + x;
            if (dst_x < 0 || dst_x >= (int)display_width) {
                continue;
            }

            size_t pixel_index = ((size_t)dst_y * display_width + dst_x) * 4;
            if (pvideo.color_key_enabled &&
                (dst[pixel_index + 2] != color_key_r ||
                 dst[pixel_index + 1] != color_key_g ||
                 dst[pixel_index + 0] != color_key_b)) {
                continue;
            }

            float out_xf = (float)x * (1.0f / MAX(pg->surface_scale_factor, 1u));
            float src_u = pvideo.in_s / 16.0f + out_xf * pvideo.scale_x;
            unsigned int src_x = MIN((unsigned int)src_u, pvideo.in_width - 1);
            uint8_t r, g, b;

            convert_yuy2_to_rgb(line, src_x, &r, &g, &b);
            dst[pixel_index + 0] = b;
            dst[pixel_index + 1] = g;
            dst[pixel_index + 2] = r;
            dst[pixel_index + 3] = 0xFF;
        }
    }
}

static uint32_t pgraph_mtl_prepare_vertices(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    GArray *expanded;

    if (!r || !r->vertex_buffer) {
        return 0;
    }

    expanded = g_array_sized_new(false, false, sizeof(MTLVertex),
                                 NV2A_MAX_BATCH_LENGTH * 6);
    r->primitive_type = MTL_PRIM_TRIANGLE;

    Nv2aVshProgram program;
    Nv2aVshProgram *program_ptr =
        pgraph_mtl_prepare_vertex_program(pg, &program) ? &program : NULL;

    if (pg->draw_arrays_length > 0) {
        for (unsigned int i = 0; i < pg->draw_arrays_length; i++) {
            unsigned int count = pg->draw_arrays_count[i];
            unsigned int start = pg->draw_arrays_start[i];
            MTLVertex *src = g_new0(MTLVertex, count);

            for (unsigned int j = 0; j < count; j++) {
                pgraph_mtl_decode_vertex_from_dma(d, start + j, program_ptr,
                                                  &src[j]);
            }
            pgraph_mtl_expand_vertices(pg, src, count, expanded,
                                       &r->primitive_type);
            g_free(src);
        }
    } else if (pg->inline_elements_length > 0) {
        unsigned int count = pg->inline_elements_length;
        MTLVertex *src = g_new0(MTLVertex, count);

        for (unsigned int i = 0; i < count; i++) {
            pgraph_mtl_decode_vertex_from_dma(d, pg->inline_elements[i],
                                              program_ptr,
                                              &src[i]);
        }
        pgraph_mtl_expand_vertices(pg, src, count, expanded,
                                   &r->primitive_type);
        g_free(src);
    } else if (pg->inline_buffer_length > 0) {
        unsigned int count = pg->inline_buffer_length;
        MTLVertex *src = g_new0(MTLVertex, count);

        for (unsigned int i = 0; i < count; i++) {
            pgraph_mtl_decode_vertex_from_inline_buffer(d, i, program_ptr,
                                                        &src[i]);
        }
        pgraph_mtl_expand_vertices(pg, src, count, expanded,
                                   &r->primitive_type);
        g_free(src);
    } else if (pg->inline_array_length > 0) {
        unsigned int vertex_size;
        unsigned int offsets[16];
        unsigned int count;
        MTLVertex *src;

        pgraph_mtl_compute_inline_array_layout(pg, &vertex_size, offsets);
        if (vertex_size == 0) {
            g_array_free(expanded, true);
            return 0;
        }

        count = pg->inline_array_length * 4 / vertex_size;
        src = g_new0(MTLVertex, count);
        for (unsigned int i = 0; i < count; i++) {
            pgraph_mtl_decode_vertex_from_inline_array(d, i, program_ptr,
                                                       &src[i]);
        }
        pgraph_mtl_expand_vertices(pg, src, count, expanded,
                                   &r->primitive_type);
        g_free(src);
    }

    r->prepared_vertex_count = expanded->len;
    if (expanded->len > 0) {
        pgraph_mtl_update_vertex_buffer_from_data(r, expanded->data,
                                                  expanded->len * sizeof(MTLVertex),
                                                  0);
    }
    g_array_free(expanded, true);
    if (program_ptr) {
        nv2a_vsh_program_destroy(&program);
    }

    return r->prepared_vertex_count;
}

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
    
    pgraph_mtl_set_display_device(r->device);
    pgraph_mtl_reload_surface_scale_factor(pg);
    
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
    pgraph_mtl_destroy_reports(r);
    pgraph_mtl_surface_destroy(r);
    pgraph_mtl_destroy_buffers(r);
    pgraph_mtl_finalize_device(r);
    if (r->display_surface_cache) {
        g_ptr_array_unref(r->display_surface_cache);
        r->display_surface_cache = NULL;
    }

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

static void pgraph_mtl_clear_report_value(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;

    if (!r || !r->report_queue) {
        pg->zpass_pixel_count_enable = false;
        return;
    }

    MTLQueryReport report = {
        .clear = true,
        .parameter = 0,
        .query_count = r->num_queries_in_flight,
    };
    g_array_append_val((GArray *)r->report_queue, report);
}

static void pgraph_mtl_clear_surface(NV2AState *d, uint32_t parameter)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
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

    r->clear_pending = true;
    memcpy(r->clear_color, rgba, sizeof(r->clear_color));

    if (r->render_encoder) {
        pgraph_mtl_clear(r, rgba[0], rgba[1], rgba[2], rgba[3]);
    }
}

static void pgraph_mtl_draw_begin(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }

    pgraph_mtl_update_viewport(d);
    r->color_format = pg->surface_shape.color_format;
    r->zeta_format = pg->surface_shape.zeta_format;
    r->texture_enable_mask = 0;
    for (unsigned int i = 0; i < NV2A_MAX_TEXTURES; i++) {
        if (pgraph_mtl_texture_stage_usable(pg, i)) {
            r->texture_enable_mask |= 1u << i;
        }
    }
    for (unsigned int i = 0; i < 4; i++) {
        uint32_t tex_ctl_0 = pgraph_reg_r(pg, NV_PGRAPH_TEXCTL0_0 + i * 4);
        uint32_t tex_fmt = pgraph_reg_r(pg, NV_PGRAPH_TEXFMT0 + i * 4);
        unsigned int color_format = GET_MASK(tex_fmt, NV_PGRAPH_TEXFMT0_COLOR);
        bool stage_usable = pgraph_mtl_texture_stage_usable(pg, i);

        r->tex_modes[i] = (r->shader_stage_program >> (i * 5)) & 0x1F;
        r->dot_map[i] = i == 0 ? 0 : (r->other_stage_input >> ((i - 1) * 4)) & 0xF;
        r->input_tex[i] = i == 0 ? UINT32_MAX :
            (i == 1 ? 0 : (r->other_stage_input >> (8 + i * 4)) & 0xF);
        r->alphakill[i] = !!(tex_ctl_0 & NV_PGRAPH_TEXCTL0_0_ALPHAKILLEN);
        r->colorkey_mode[i] = tex_ctl_0 & NV_PGRAPH_TEXCTL0_0_COLORKEYMODE;
        r->color_key[i] = pgraph_reg_r(pg, NV_PGRAPH_COLORKEYCOLOR0 + i * 4);
        r->color_key_mask[i] = pgraph_mtl_get_color_key_mask_for_texture(pg, i);
        r->rect_tex[i] = (stage_usable &&
                          color_format < ARRAY_SIZE(kelvin_color_format_info_map))
                             ? kelvin_color_format_info_map[color_format].linear
                             : 0;
        r->tex_cubemap[i] = !!GET_MASK(tex_fmt, NV_PGRAPH_TEXFMT0_CUBEMAPENABLE);
        r->dim_tex[i] = GET_MASK(tex_fmt, NV_PGRAPH_TEXFMT0_DIMENSIONALITY);
        for (unsigned int j = 0; j < 4; j++) {
            r->compare_mode[i][j] =
                (pgraph_reg_r(pg, NV_PGRAPH_SHADERCLIPMODE) >> (4 * i + j)) & 1;
        }
        if (i > 0) {
            uint32_t m00 = pgraph_reg_r(pg, NV_PGRAPH_BUMPMAT00 + 4 * (i - 1));
            uint32_t m01 = pgraph_reg_r(pg, NV_PGRAPH_BUMPMAT01 + 4 * (i - 1));
            uint32_t m10 = pgraph_reg_r(pg, NV_PGRAPH_BUMPMAT10 + 4 * (i - 1));
            uint32_t m11 = pgraph_reg_r(pg, NV_PGRAPH_BUMPMAT11 + 4 * (i - 1));
            uint32_t bump_scale = pgraph_reg_r(pg, NV_PGRAPH_BUMPSCALE1 + (i - 1) * 4);
            uint32_t bump_offset = pgraph_reg_r(pg, NV_PGRAPH_BUMPOFFSET1 + (i - 1) * 4);

            r->bump_mat[i][0] = *(float *)&m00;
            r->bump_mat[i][1] = *(float *)&m01;
            r->bump_mat[i][2] = *(float *)&m10;
            r->bump_mat[i][3] = *(float *)&m11;
            r->bump_scale[i] = *(float *)&bump_scale;
            r->bump_offset[i] = *(float *)&bump_offset;
        } else {
            memset(r->bump_mat[i], 0, sizeof(r->bump_mat[i]));
            r->bump_scale[i] = 0.0f;
            r->bump_offset[i] = 0.0f;
        }
    }
    r->alpha_test_enabled =
        pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0) &
        NV_PGRAPH_CONTROL_0_ALPHATESTENABLE;
    r->alpha_func = GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0),
                             NV_PGRAPH_CONTROL_0_ALPHAFUNC);
    r->alpha_ref = (float)GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0),
                                   NV_PGRAPH_CONTROL_0_ALPHAREF) /
                   255.0f;
    r->blend_reg = pgraph_reg_r(pg, NV_PGRAPH_BLEND);
    r->blend_color_reg = pgraph_reg_r(pg, NV_PGRAPH_BLENDCOLOR);
    r->control_0_reg = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_0);
    r->control_1_reg = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_1);
    r->control_2_reg = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_2);
    r->control_3_reg = pgraph_reg_r(pg, NV_PGRAPH_CONTROL_3);
    r->setup_raster_reg = pgraph_reg_r(pg, NV_PGRAPH_SETUPRASTER);
    r->zoffset_bias_reg = pgraph_reg_r(pg, NV_PGRAPH_ZOFFSETBIAS);
    r->zoffset_factor_reg = pgraph_reg_r(pg, NV_PGRAPH_ZOFFSETFACTOR);
    r->combiner_control = pgraph_reg_r(pg, NV_PGRAPH_COMBINECTL);
    r->shader_stage_program = pgraph_reg_r(pg, NV_PGRAPH_SHADERPROG);
    r->other_stage_input = pgraph_reg_r(pg, NV_PGRAPH_SHADERCTL);
    r->final_inputs_0 = pgraph_reg_r(pg, NV_PGRAPH_COMBINESPECFOG0);
    r->final_inputs_1 = pgraph_reg_r(pg, NV_PGRAPH_COMBINESPECFOG1);
    for (unsigned int i = 0; i < 8; i++) {
        r->rgb_inputs[i] = pgraph_reg_r(pg, NV_PGRAPH_COMBINECOLORI0 + i * 4);
        r->rgb_outputs[i] = pgraph_reg_r(pg, NV_PGRAPH_COMBINECOLORO0 + i * 4);
        r->alpha_inputs[i] = pgraph_reg_r(pg, NV_PGRAPH_COMBINEALPHAI0 + i * 4);
        r->alpha_outputs[i] = pgraph_reg_r(pg, NV_PGRAPH_COMBINEALPHAO0 + i * 4);
    }
    for (unsigned int i = 0; i < 9; i++) {
        uint32_t c0 = i == 8 ? pgraph_reg_r(pg, NV_PGRAPH_SPECFOGFACTOR0)
                             : pgraph_reg_r(pg, NV_PGRAPH_COMBINEFACTOR0 + i * 4);
        uint32_t c1 = i == 8 ? pgraph_reg_r(pg, NV_PGRAPH_SPECFOGFACTOR1)
                             : pgraph_reg_r(pg, NV_PGRAPH_COMBINEFACTOR1 + i * 4);
        pgraph_argb_pack32_to_rgba_float(c0, r->combiner_consts[i * 2]);
        pgraph_argb_pack32_to_rgba_float(c1, r->combiner_consts[i * 2 + 1]);
    }
    pgraph_argb_pack32_to_rgba_float(pgraph_reg_r(pg, NV_PGRAPH_FOGCOLOR),
                                     r->fog_color);
    pgraph_mtl_surface_update(r);
    pgraph_mtl_begin_command_buffer(r);
    pgraph_mtl_bind_textures(d);
    pgraph_mtl_bind_vertex_data(d);
}

static void pgraph_mtl_draw_end(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    uint32_t vertex_count = pgraph_mtl_prepare_vertices(d);

    if (vertex_count > 0) {
        pgraph_mtl_draw(r, false, 0, vertex_count);
    }
    
    pgraph_mtl_end_command_buffer(r);
    pgraph_mtl_submit_command_buffer(r);
}

static void pgraph_mtl_flush_draw(NV2AState *d)
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

static void pgraph_mtl_surface_update_callback(NV2AState *d, bool upload,
                                               bool color_write,
                                               bool zeta_write)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }

    if (upload && color_write && r->surface_color) {
        DMAObject dma = nv_dma_load(d, pg->dma_color);
        unsigned int width = pg->surface_binding_dim.width;
        unsigned int height = pg->surface_binding_dim.height;
        unsigned int bpp = pgraph_mtl_surface_color_bytes_per_pixel(
            pg->surface_shape.color_format);
        unsigned int scale = MAX(1u, pg->surface_scale_factor);
        bool swizzle =
            pg->surface_type == NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE;
        hwaddr surface_addr;
        hwaddr surface_size;
        uint8_t *src;
        uint8_t *buf;
        uint8_t *linear_buf = NULL;
        unsigned int linear_pitch;

        surface_size = (hwaddr)pg->surface_color.pitch * height;
        if (dma.dma_class == NV_DMA_IN_MEMORY_CLASS && width && height &&
            pg->surface_color.offset <= dma.limit) {
            surface_addr = dma.address + pg->surface_color.offset;
        } else {
            surface_addr = memory_region_size(d->vram);
        }

        if (surface_addr < memory_region_size(d->vram) &&
            surface_addr + surface_size <= memory_region_size(d->vram)) {
            src = d->vram_ptr + surface_addr;
            buf = src;

            if (swizzle) {
                buf = g_malloc(height * pg->surface_color.pitch);
                unswizzle_rect(src, width, height, buf,
                               pg->surface_color.pitch, bpp);
            }

            linear_pitch = width * bpp;
            if (pg->surface_color.pitch != linear_pitch) {
                linear_buf = g_malloc(height * linear_pitch);
                for (unsigned int y = 0; y < height; y++) {
                    memcpy(linear_buf + y * linear_pitch,
                           buf + y * pg->surface_color.pitch,
                           linear_pitch);
                }
            } else {
                linear_buf = buf;
            }

            if (scale > 1) {
                uint8_t *scaled = g_malloc(width * height * bpp * scale * scale);
                pgraph_mtl_surface_copy_expand(scaled, linear_buf, width,
                                               height, bpp, scale);
                if (linear_buf != buf) {
                    g_free(linear_buf);
                }
                linear_buf = scaled;
                width *= scale;
                height *= scale;
                linear_pitch = width * bpp;
            }

            if (bpp != 4 ||
                (pg->surface_shape.color_format !=
                     NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8 &&
                 pg->surface_shape.color_format !=
                     NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8 &&
                 pg->surface_shape.color_format !=
                     NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8 &&
                 pg->surface_shape.color_format !=
                     NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8 &&
                 pg->surface_shape.color_format !=
                     NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8)) {
                uint8_t *converted = pgraph_mtl_surface_convert_to_bgra8(
                    linear_buf, width, height, linear_pitch,
                    pg->surface_shape.color_format);
                if (linear_buf != buf) {
                    g_free(linear_buf);
                }
                linear_buf = converted;
                linear_pitch = width * 4;
            }

            pgraph_mtl_surface_upload_color(r, linear_buf, width, height,
                                            linear_pitch);

            if (linear_buf != buf) {
                g_free(linear_buf);
            }
            if (swizzle) {
                g_free(buf);
            }
        }
    }

    if (upload && zeta_write && r->surface_zeta) {
        DMAObject dma = nv_dma_load(d, pg->dma_zeta);
        unsigned int width = pg->surface_binding_dim.width;
        unsigned int height = pg->surface_binding_dim.height;
        unsigned int bpp = pgraph_mtl_surface_zeta_bytes_per_pixel(
            pg->surface_shape.zeta_format);
        unsigned int scale = MAX(1u, pg->surface_scale_factor);
        bool swizzle =
            pg->surface_type == NV097_SET_SURFACE_FORMAT_TYPE_SWIZZLE;
        hwaddr surface_addr;
        hwaddr surface_size;
        uint8_t *src;
        uint8_t *buf;
        uint8_t *linear_buf = NULL;
        unsigned int linear_pitch;

        surface_size = (hwaddr)pg->surface_zeta.pitch * height;
        if (dma.dma_class == NV_DMA_IN_MEMORY_CLASS && width && height &&
            pg->surface_zeta.offset <= dma.limit) {
            surface_addr = dma.address + pg->surface_zeta.offset;
        } else {
            surface_addr = memory_region_size(d->vram);
        }

        if (surface_addr < memory_region_size(d->vram) &&
            surface_addr + surface_size <= memory_region_size(d->vram)) {
            src = d->vram_ptr + surface_addr;
            buf = src;

            if (swizzle) {
                buf = g_malloc(height * pg->surface_zeta.pitch);
                unswizzle_rect(src, width, height, buf,
                               pg->surface_zeta.pitch, bpp);
            }

            linear_pitch = width * bpp;
            if (pg->surface_zeta.pitch != linear_pitch) {
                linear_buf = g_malloc(height * linear_pitch);
                for (unsigned int y = 0; y < height; y++) {
                    memcpy(linear_buf + y * linear_pitch,
                           buf + y * pg->surface_zeta.pitch,
                           linear_pitch);
                }
            } else {
                linear_buf = buf;
            }

            if (scale > 1) {
                uint8_t *scaled = g_malloc(width * height * bpp * scale * scale);
                pgraph_mtl_surface_copy_expand(scaled, linear_buf, width,
                                               height, bpp, scale);
                if (linear_buf != buf) {
                    g_free(linear_buf);
                }
                linear_buf = scaled;
                width *= scale;
                height *= scale;
                linear_pitch = width * bpp;
            }

            if (pg->surface_shape.zeta_format == NV097_SET_SURFACE_FORMAT_ZETA_Z16) {
                pgraph_mtl_surface_upload_zeta(r, linear_buf, width, height,
                                               linear_pitch);
            } else {
                typedef struct ZetaPixel {
                    float depth;
                    uint32_t stencil;
                } ZetaPixel;
                ZetaPixel *packed = g_new(ZetaPixel, width * height);

                for (unsigned int y = 0; y < height; y++) {
                    uint32_t *row = (uint32_t *)(linear_buf + y * linear_pitch);
                    for (unsigned int x = 0; x < width; x++) {
                        uint32_t v = row[x];
                        packed[y * width + x].depth =
                            (float)(v & 0x00FFFFFF) / 16777215.0f;
                        packed[y * width + x].stencil = v >> 24;
                    }
                }
                pgraph_mtl_surface_upload_zeta(r, packed, width, height,
                                               width * sizeof(ZetaPixel));
                g_free(packed);
            }

            if (linear_buf != buf) {
                g_free(linear_buf);
            }
            if (swizzle) {
                g_free(buf);
            }
        }
    }

    pgraph_mtl_surface_update_from_vram(d, upload, color_write, zeta_write);
}

void pgraph_mtl_surface_update_from_vram(NV2AState *d, bool upload,
                                         bool color_write, bool zeta_write)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;

    if (!r) {
        return;
    }

    if (!upload || (!color_write && !zeta_write)) {
        r->display_valid = false;
        return;
    }

    r->framebuffer_texture = r->surface_color;

    if (color_write && !pgraph_mtl_display_refresh(r)) {
        r->display_valid = false;
    }
}

static void pgraph_mtl_update_display_size(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    unsigned int width;
    unsigned int height;
    VGADisplayParams vga_display_params;

    if (!r) {
        return;
    }

    d->vga.get_resolution(&d->vga, (int *)&width, (int *)&height);
    d->vga.get_params(&d->vga, &vga_display_params);

    if (d->vga.cr[NV_PRMCIO_INTERLACE_MODE] !=
        NV_PRMCIO_INTERLACE_MODE_DISABLED) {
        height *= 2;
    }

    pgraph_apply_scaling_factor(pg, &width, &height);

    if (width < 64 || height < 64) {
        if (r->display_width >= 64 && r->display_height >= 64) {
            return;
        }
    }

    if (width == 0 || height == 0) {
        width = 640;
        height = 480;
    }

    pgraph_mtl_display_set_size(r, width, height);
}

bool pgraph_mtl_update_display_from_scanout(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    VGADisplayParams vga_display_params;
    unsigned int width;
    unsigned int height;
    unsigned int scaled_width;
    unsigned int scaled_height;
    unsigned int scale;
    uint8_t *scanout = NULL;
    uint8_t *scaled = NULL;
    int bpp;
    bool ok = false;

    if (!r || !r->display_texture) {
        return false;
    }

    d->vga.get_resolution(&d->vga, (int *)&width, (int *)&height);
    d->vga.get_params(&d->vga, &vga_display_params);
    bpp = d->vga.get_bpp ? d->vga.get_bpp(&d->vga) : 0;

    if (!width || !height || !vga_display_params.line_offset || bpp <= 0) {
        r->display_valid = false;
        return false;
    }

    if (d->vga.cr[NV_PRMCIO_INTERLACE_MODE] !=
        NV_PRMCIO_INTERLACE_MODE_DISABLED) {
        height *= 2;
    }

    if (d->pcrtc.start + (hwaddr)vga_display_params.line_offset * height >
        memory_region_size(d->vram)) {
        r->display_valid = false;
        return false;
    }

    scale = MAX(pg->surface_scale_factor, 1);
    scaled_width = width;
    scaled_height = height;
    pgraph_apply_scaling_factor(pg, &scaled_width, &scaled_height);

    if (r->display_width != scaled_width || r->display_height != scaled_height) {
        pgraph_mtl_display_set_size(r, scaled_width, scaled_height);
        if (!r->display_texture) {
            return false;
        }
    }

    if (pgraph_mtl_update_display_from_surface(d, scaled_width, scaled_height)) {
        return true;
    }

    scanout = pgraph_mtl_convert_scanout_from_bpp(
        d->vram_ptr + d->pcrtc.start, width, height,
        vga_display_params.line_offset, bpp);

    if (scale > 1) {
        scaled = g_malloc(scaled_width * scaled_height * 4);
        pgraph_mtl_surface_copy_expand(scaled, scanout, width, height, 4,
                                       scale);
        g_free(scanout);
        scanout = scaled;
    }

    pgraph_mtl_apply_pvideo_overlay(d, scanout, scaled_width, scaled_height);

    ok = pgraph_mtl_display_upload(r, scanout, scaled_width, scaled_height,
                                   scaled_width * 4);
    g_free(scanout);
    return ok;
}

void pgraph_mtl_surface_flush(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }

    pgraph_mtl_update_viewport(d);
    r->color_format = pg->surface_shape.color_format;
    r->zeta_format = pg->surface_shape.zeta_format;
    pgraph_mtl_surface_update(r);
    
    if (r->surface_color || r->surface_zeta) {
        pgraph_mtl_surface_update_callback(d, true, true, true);
        pgraph_mtl_snapshot_current_surface(d);
        pgraph_mtl_update_display_size(d);
    }
}

static void pgraph_mtl_get_report(NV2AState *d, uint32_t parameter)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;

    if (!r || !r->report_queue) {
        pgraph_write_zpass_pixel_cnt_report(d, parameter, 0);
        return;
    }

    MTLQueryReport report = {
        .clear = false,
        .parameter = parameter,
        .query_count = r->num_queries_in_flight,
    };
    g_array_append_val((GArray *)r->report_queue, report);
}

static void pgraph_mtl_image_blit_wrapper(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    pgraph_mtl_image_blit(pg->mtl_renderer_state);
}

static void pgraph_mtl_set_surface_scale_factor(NV2AState *d, unsigned int scale)
{
    PGRAPHState *pg = &d->pgraph;

    g_config.display.quality.surface_scale = MAX(scale, 1);
    pg->surface_scale_factor = MAX(scale, 1);
    pgraph_mtl_update_display_size(d);
}

static unsigned int pgraph_mtl_get_surface_scale_factor(NV2AState *d)
{
    return MAX(d->pgraph.surface_scale_factor, 1);
}

static int pgraph_mtl_get_framebuffer_surface(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    unsigned int gl_texture;

    if (!r || !r->display_texture || !r->display_valid) {
        return 0;
    }

    qemu_mutex_lock(&d->pfifo.lock);
    qemu_event_reset(&d->pgraph.sync_complete);
    qatomic_set(&pg->sync_pending, true);
    pfifo_kick(d);
    qemu_mutex_unlock(&d->pfifo.lock);
    qemu_event_wait(&d->pgraph.sync_complete);

    if (!r->display_texture || !r->display_valid ||
        r->display_width == 0 || r->display_height == 0) {
        return 0;
    }

    gl_texture = pgraph_mtl_display_get_gl_texture(r->device,
                                                   r->display_texture,
                                                   r->display_width,
                                                   r->display_height);
    return gl_texture;
}

static void pgraph_mtl_flip_stall(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_flush_draw(d);
}

static void pgraph_mtl_sync(NV2AState *d)
{
    PGRAPHMTLState *r = d->pgraph.mtl_renderer_state;

    pgraph_mtl_flush_draw(d);
    if (r) {
        pgraph_mtl_wait_idle(r);
    }
    pgraph_mtl_snapshot_current_surface(d);
    pgraph_mtl_update_display_from_scanout(d);

    qatomic_set(&d->pgraph.sync_pending, false);
    qemu_event_set(&d->pgraph.sync_complete);
}

static void pgraph_mtl_flush_pending(NV2AState *d)
{
    PGRAPHMTLState *r = d->pgraph.mtl_renderer_state;

    pgraph_mtl_surface_flush(d);
    if (r) {
        pgraph_mtl_wait_idle(r);
    }
    pgraph_mtl_snapshot_current_surface(d);

    qatomic_set(&d->pgraph.flush_pending, false);
    qemu_event_set(&d->pgraph.flush_complete);
}

static void pgraph_mtl_process_pending(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;

    if (qatomic_read(&pg->sync_pending) || qatomic_read(&pg->flush_pending)) {
        qemu_mutex_unlock(&d->pfifo.lock);
        qemu_mutex_lock(&pg->lock);
        if (qatomic_read(&pg->sync_pending)) {
            pgraph_mtl_sync(d);
        }
        if (qatomic_read(&pg->flush_pending)) {
            pgraph_mtl_flush_pending(d);
        }
        qemu_mutex_unlock(&pg->lock);
        qemu_mutex_lock(&d->pfifo.lock);
    }
}

static void pgraph_mtl_process_pending_reports(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }

    if (!r->report_queue) {
        return;
    }

    if (r->num_queries_in_flight > 0) {
        g_autofree uint64_t *query_results =
            g_new0(uint64_t, r->num_queries_in_flight);
        uint32_t result_count = pgraph_mtl_copy_query_results(
            r, query_results, r->num_queries_in_flight);
        uint32_t num_results_counted = 0;
        uint32_t result_divisor = MAX(
            1, pg->surface_scale_factor * pg->surface_scale_factor);
        GArray *queue = (GArray *)r->report_queue;

        for (guint i = 0; i < queue->len; i++) {
            MTLQueryReport *report = &g_array_index(queue, MTLQueryReport, i);

            while (num_results_counted < report->query_count &&
                   num_results_counted < result_count) {
                r->zpass_pixel_count_result +=
                    query_results[num_results_counted++];
            }

            if (report->clear) {
                r->zpass_pixel_count_result = 0;
            } else {
                pgraph_write_zpass_pixel_cnt_report(
                    d, report->parameter,
                    r->zpass_pixel_count_result / result_divisor);
            }
        }

        g_array_set_size(queue, 0);
        r->num_queries_in_flight = 0;
        r->query_in_flight = false;
    }
}

static void pgraph_mtl_pre_savevm_trigger(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_flush(r);
    pgraph_mtl_submit(r);
}

static void pgraph_mtl_pre_savevm_wait(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_wait_idle(r);
}

static void pgraph_mtl_pre_shutdown_trigger(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    pgraph_mtl_flush(r);
    pgraph_mtl_submit(r);
}

static void pgraph_mtl_pre_shutdown_wait(NV2AState *d)
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
        bool enabled = pgraph_mtl_texture_stage_usable(pg, i);
        
        if (!enabled) {
            continue;
        }
        
        TextureShape state = pgraph_get_texture_shape(pg, i);
        PGRAPHMTLTextureShape mshape = {
            .cubemap = state.cubemap,
            .dimensionality = state.dimensionality,
            .color_format = state.color_format,
            .levels = state.levels,
            .width = state.width,
            .height = state.height,
            .depth = state.depth,
            .border = state.border,
            .min_mipmap_level = state.min_mipmap_level,
            .max_mipmap_level = state.max_mipmap_level,
            .pitch = state.pitch,
        };
        hwaddr texture_vram_offset = pgraph_get_texture_phys_addr(pg, i);
        size_t length = pgraph_get_texture_length(pg, &state);
        
        if (texture_vram_offset >= memory_region_size(d->vram)) {
            continue;
        }
        
        if ((texture_vram_offset + length) > memory_region_size(d->vram)) {
            length = memory_region_size(d->vram) - texture_vram_offset;
        }
        
        uint8_t *texture_data = d->vram_ptr + texture_vram_offset;
        
        size_t palette_length = 0;
        hwaddr palette_vram_offset =
            pgraph_get_texture_palette_phys_addr_length(pg, i,
                                                        &palette_length);
        const uint8_t *palette_data = NULL;
        if (palette_vram_offset < memory_region_size(d->vram) &&
            palette_vram_offset + palette_length <= memory_region_size(d->vram)) {
            palette_data = d->vram_ptr + palette_vram_offset;
        }
        
        pgraph_mtl_setup_texture_stage(
            r, i,
            pgraph_reg_r(pg, NV_PGRAPH_TEXFILTER0 + i * 4),
            pgraph_reg_r(pg, NV_PGRAPH_TEXADDRESS0 + i * 4));

        pgraph_mtl_upload_texture(r, i, &mshape, texture_data, length,
                                  palette_data, palette_length);
    }
}

void pgraph_mtl_bind_vertex_data(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHMTLState *r = pg->mtl_renderer_state;
    
    if (!r) {
        return;
    }
    
    r->prepared_vertex_count = 0;
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

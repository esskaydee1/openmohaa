/*
===========================================================================
renderer_metalrt - native Metal ray-traced renderer for OpenMoHAA.
See code/renderer_metalrt/CLAUDE.md and docs/ for scope and hard rules.
===========================================================================
*/
#ifndef __RT_LOCAL_H
#define __RT_LOCAL_H

#include "../qcommon/q_shared.h"
#include "../qcommon/qfiles.h"
#include "../renderercommon/tr_public.h"

// Deliberately does NOT include tr_common.h/qgl.h - this renderer never
// touches OpenGL/GLES, so there's no reason to pull in the qgl* function
// pointer table or SDL_opengl.h.

// Session 13: blend-mode classification for a .shader's `blendfunc`,
// shared between rt_image.mm's shader-script parser
// (RT_FindShaderScriptTexture) and rt_scene.mm's per-surface pipeline
// selection. Deliberately a coarse 3-way bucket, not a faithful mapping
// of every GL src/dst blend factor combination Metal could represent -
// RT_BLEND_ALPHA also covers the real "filter" (multiply-darken) blend
// preset, an approximation, not a fourth pipeline variant.
// Session 20: RT_BLEND_ALPHATEST is a separate bucket from RT_BLEND_ALPHA -
// a shader's `alphaFunc` (alpha-cutout, e.g. foliage: fully opaque leaf
// or fully invisible gap, no in-between) is a qualitatively different
// technique from `blendFunc` (smooth alpha blending, e.g. glass/smoke),
// not just another blend-factor combination. Mapping alphaFunc onto
// RT_BLEND_ALPHA would blend a leaf's edges into whatever's behind it
// instead of cutting them out, and would skip writing depth where real
// alpha-tested surfaces should.
typedef enum {
	RT_BLEND_OPAQUE,
	RT_BLEND_ALPHA,
	RT_BLEND_ADDITIVE,
	RT_BLEND_ALPHATEST
} rtBlendMode_t;

#ifdef __cplusplus
extern "C" {
#endif

// Engine imports, captured once in GetRefAPI.
extern refimport_t ri;

// Reported to the client via BeginRegistration; kept up to date by
// whatever (currently just startup) creates/resizes the window.
extern glconfig_t rtGlConfig;

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
// Accessors into rt_init.mm's module state, for the drawing/image code
// (also .mm, so these Objective-C types are safe to expose here; a
// plain .cpp translation unit like rt_stubs.cpp never sees this block).
#import <Metal/Metal.h>
id<MTLDevice> RT_GetDevice( void );
// The render command encoder for the frame currently being built by
// RE_BeginFrame/RE_EndFrame, or nil outside of one - draw calls between
// those two calls encode into this.
id<MTLRenderCommandEncoder> RT_GetCurrentEncoder( void );
#endif

// One-time-per-call-site logging for functions that aren't implemented
// yet: loud on first use (impossible to miss in the log), silent after
// that so a function called every frame doesn't flood the console.
// Never a silent no-op on the FIRST call, per CLAUDE.md rule 4. Each
// macro expansion gets its own function-local static, so this correctly
// warns once per STUB FUNCTION, not once globally.
#define RT_STUB_ONCE() \
	do { \
		static bool rtStubWarned = false; \
		if ( !rtStubWarned ) { \
			rtStubWarned = true; \
			ri.Printf( PRINT_WARNING, "renderer_metalrt: %s not implemented yet\n", __func__ ); \
		} \
	} while ( 0 )

#endif // __RT_LOCAL_H

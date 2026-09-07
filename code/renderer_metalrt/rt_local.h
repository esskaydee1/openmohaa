/*
===========================================================================
renderer_metalrt - native Metal ray-traced renderer for OpenMoHAA.
See code/renderer_metalrt/CLAUDE.md and docs/ for scope and hard rules.
===========================================================================
*/
#ifndef __RT_LOCAL_H
#define __RT_LOCAL_H

#include "../qcommon/q_shared.h"
#include "../renderercommon/tr_public.h"

// Deliberately does NOT include tr_common.h/qgl.h - this renderer never
// touches OpenGL/GLES, so there's no reason to pull in the qgl* function
// pointer table or SDL_opengl.h.

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

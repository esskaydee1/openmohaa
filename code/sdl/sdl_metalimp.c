/*
===========================================================================
Copyright (C) 1999-2005 Id Software, Inc.

This file is part of Quake III Arena source code.

Quake III Arena source code is free software; you can redistribute it
and/or modify it under the terms of the GNU General Public License as
published by the Free Software Foundation; either version 2 of the License,
or (at your option) any later version.

Quake III Arena source code is distributed in the hope that it will be
useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Quake III Arena source code; if not, write to the Free Software
Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
===========================================================================
*/
/*
** sdl_metalimp.c
**
** Window/context creation for the Metal renderer target: same job as
** sdl_glimp.c, but instead of a real SDL_GL_CreateContext, this drives
** Google's ANGLE (its Metal backend) through EGL against an SDL Metal view's
** CAMetalLayer. ANGLE translates the GLES3 calls the renderer makes into
** native Metal, bypassing Apple's slow generic OpenGL-over-Metal shim.
**
** This backend is always used with the GL2 renderer sources (never GL1), so
** unlike sdl_glimp.c there is no fixed-function/ES-vs-desktop branching here:
** it's GLES3 via ANGLE, full stop.
*/

#ifdef USE_INTERNAL_SDL_HEADERS
#	include "SDL.h"
#	include "SDL_metal.h"
#else
#	include <SDL.h>
#	include <SDL_metal.h>
#endif

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "../renderercommon/tr_common.h"
#include "../sys/sys_local.h"
#include "sdl_icon.h"

typedef enum
{
	RSERR_OK,

	RSERR_INVALID_FULLSCREEN,
	RSERR_INVALID_MODE,

	RSERR_UNKNOWN
} rserr_t;

SDL_Window *SDL_window = NULL;

static SDL_MetalView metalView = NULL;
static EGLDisplay eglDisplay = EGL_NO_DISPLAY;
static EGLConfig  eglConfig;
static EGLSurface eglSurface = EGL_NO_SURFACE;
static EGLContext eglContext = EGL_NO_CONTEXT;

cvar_t *r_allowResize; // make window resizable
cvar_t *r_centerWindow;
cvar_t *r_sdlDriver;

int qglMajorVersion, qglMinorVersion;
int qglesMajorVersion, qglesMinorVersion;

void (APIENTRYP qglActiveTextureARB) (GLenum texture);
void (APIENTRYP qglClientActiveTextureARB) (GLenum texture);
void (APIENTRYP qglMultiTexCoord2fARB) (GLenum target, GLfloat s, GLfloat t);

void (APIENTRYP qglLockArraysEXT) (GLint first, GLsizei count);
void (APIENTRYP qglUnlockArraysEXT) (void);

#define GLE(ret, name, ...) name##proc * qgl##name = NULL;
QGL_1_1_PROCS;
QGL_1_1_FIXED_FUNCTION_PROCS;
QGL_DESKTOP_1_1_PROCS;
QGL_DESKTOP_1_1_FIXED_FUNCTION_PROCS;
QGL_ES_1_1_PROCS;
QGL_ES_1_1_FIXED_FUNCTION_PROCS;
QGL_1_3_PROCS;
QGL_1_5_PROCS;
QGL_2_0_PROCS;
QGL_3_0_PROCS;
QGL_ARB_occlusion_query_PROCS;
QGL_ARB_framebuffer_object_PROCS;
QGL_ARB_vertex_array_object_PROCS;
QGL_EXT_direct_state_access_PROCS;
#undef GLE

/*
===============
Metal_InitDisplay

Creates the EGLDisplay for ANGLE's Metal backend, if not already created.
This is a process-wide connection to the driver, independent of any
particular window, so it's created once and reused across mode changes.
===============
*/
static qboolean Metal_InitDisplay( void )
{
	EGLAttrib displayAttribs[] = {
		EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
		EGL_NONE,
	};
	EGLint major, minor;

	if ( eglDisplay != EGL_NO_DISPLAY )
		return qtrue;

	eglDisplay = eglGetPlatformDisplay( EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, displayAttribs );
	if ( eglDisplay == EGL_NO_DISPLAY )
	{
		ri.Printf( PRINT_ALL, "eglGetPlatformDisplay failed: 0x%x\n", eglGetError() );
		return qfalse;
	}

	if ( !eglInitialize( eglDisplay, &major, &minor ) )
	{
		ri.Printf( PRINT_ALL, "eglInitialize failed: 0x%x\n", eglGetError() );
		eglDisplay = EGL_NO_DISPLAY;
		return qfalse;
	}

	ri.Printf( PRINT_ALL, "EGL %d.%d via ANGLE (%s)\n", major, minor, eglQueryString( eglDisplay, EGL_VERSION ) );

	return qtrue;
}

/*
===============
Metal_CreateSurfaceAndContext

Picks an EGL config against the given CAMetalLayer and creates a GLES3
context+surface for it, retrying once with relaxed requirements if the
requested depth/stencil/MSAA combination isn't available.
===============
*/
static qboolean Metal_CreateSurfaceAndContext( void *metalLayer, int depthBits, int stencilBits, int samples )
{
	EGLint numConfigs = 0;
	EGLint configAttribs[16];
	int i;
	EGLint contextAttribs[] = {
		EGL_CONTEXT_MAJOR_VERSION, 3,
		EGL_CONTEXT_MINOR_VERSION, 0,
		EGL_NONE,
	};

	i = 0;
	configAttribs[i++] = EGL_SURFACE_TYPE;    configAttribs[i++] = EGL_WINDOW_BIT;
	configAttribs[i++] = EGL_RENDERABLE_TYPE; configAttribs[i++] = EGL_OPENGL_ES3_BIT;
	configAttribs[i++] = EGL_RED_SIZE;        configAttribs[i++] = 8;
	configAttribs[i++] = EGL_GREEN_SIZE;      configAttribs[i++] = 8;
	configAttribs[i++] = EGL_BLUE_SIZE;       configAttribs[i++] = 8;
	configAttribs[i++] = EGL_ALPHA_SIZE;      configAttribs[i++] = 8;
	configAttribs[i++] = EGL_DEPTH_SIZE;      configAttribs[i++] = depthBits;
	configAttribs[i++] = EGL_STENCIL_SIZE;    configAttribs[i++] = stencilBits;
	configAttribs[i++] = EGL_NONE;

	if ( !eglChooseConfig( eglDisplay, configAttribs, &eglConfig, 1, &numConfigs ) || numConfigs == 0 )
	{
		ri.Printf( PRINT_ALL, "...requested EGL config unavailable (depth=%d stencil=%d), retrying with defaults\n",
			depthBits, stencilBits );

		i = 0;
		configAttribs[i++] = EGL_SURFACE_TYPE;    configAttribs[i++] = EGL_WINDOW_BIT;
		configAttribs[i++] = EGL_RENDERABLE_TYPE; configAttribs[i++] = EGL_OPENGL_ES3_BIT;
		configAttribs[i++] = EGL_RED_SIZE;        configAttribs[i++] = 8;
		configAttribs[i++] = EGL_GREEN_SIZE;      configAttribs[i++] = 8;
		configAttribs[i++] = EGL_BLUE_SIZE;       configAttribs[i++] = 8;
		configAttribs[i++] = EGL_DEPTH_SIZE;      configAttribs[i++] = 24;
		configAttribs[i++] = EGL_STENCIL_SIZE;    configAttribs[i++] = 8;
		configAttribs[i++] = EGL_NONE;

		if ( !eglChooseConfig( eglDisplay, configAttribs, &eglConfig, 1, &numConfigs ) || numConfigs == 0 )
		{
			ri.Printf( PRINT_ALL, "eglChooseConfig failed: 0x%x\n", eglGetError() );
			return qfalse;
		}
	}

	// Multisampling is intentionally not requested through the EGL config:
	// GL2's postprocess pipeline does its own offscreen FBO rendering and
	// resolve, and ANGLE's Metal-backed default framebuffer MSAA support is
	// not something we've validated here. r_ext_multisample stays a no-op
	// for this backend rather than risk eglChooseConfig failing outright.
	(void)samples;

	eglSurface = eglCreateWindowSurface( eglDisplay, eglConfig, (EGLNativeWindowType)metalLayer, NULL );
	if ( eglSurface == EGL_NO_SURFACE )
	{
		ri.Printf( PRINT_ALL, "eglCreateWindowSurface failed: 0x%x\n", eglGetError() );
		return qfalse;
	}

	eglContext = eglCreateContext( eglDisplay, eglConfig, EGL_NO_CONTEXT, contextAttribs );
	if ( eglContext == EGL_NO_CONTEXT )
	{
		ri.Printf( PRINT_ALL, "eglCreateContext failed: 0x%x\n", eglGetError() );
		eglDestroySurface( eglDisplay, eglSurface );
		eglSurface = EGL_NO_SURFACE;
		return qfalse;
	}

	if ( !eglMakeCurrent( eglDisplay, eglSurface, eglSurface, eglContext ) )
	{
		ri.Printf( PRINT_ALL, "eglMakeCurrent failed: 0x%x\n", eglGetError() );
		eglDestroyContext( eglDisplay, eglContext );
		eglContext = EGL_NO_CONTEXT;
		eglDestroySurface( eglDisplay, eglSurface );
		eglSurface = EGL_NO_SURFACE;
		return qfalse;
	}

	return qtrue;
}

/*
===============
Metal_DestroySurfaceAndContext

Tears down the current surface+context, but leaves the EGLDisplay (and the
ANGLE driver connection it represents) alive for reuse by the next mode set.
===============
*/
static void Metal_DestroySurfaceAndContext( void )
{
	if ( eglDisplay == EGL_NO_DISPLAY )
		return;

	eglMakeCurrent( eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT );

	if ( eglContext != EGL_NO_CONTEXT )
	{
		eglDestroyContext( eglDisplay, eglContext );
		eglContext = EGL_NO_CONTEXT;
	}

	if ( eglSurface != EGL_NO_SURFACE )
	{
		eglDestroySurface( eglDisplay, eglSurface );
		eglSurface = EGL_NO_SURFACE;
	}
}

/*
===============
GLimp_Shutdown
===============
*/
void GLimp_Shutdown( void )
{
	ri.IN_Shutdown();

	Metal_DestroySurfaceAndContext();

	if ( eglDisplay != EGL_NO_DISPLAY )
	{
		eglTerminate( eglDisplay );
		eglDisplay = EGL_NO_DISPLAY;
	}

	if ( metalView != NULL )
	{
		SDL_Metal_DestroyView( metalView );
		metalView = NULL;
	}

	SDL_QuitSubSystem( SDL_INIT_VIDEO );
}

/*
===============
GLimp_Minimize

Minimize the game so that user is back at the desktop
===============
*/
void GLimp_Minimize( void )
{
	SDL_MinimizeWindow( SDL_window );
}

/*
===============
GLimp_LogComment
===============
*/
void GLimp_LogComment( char *comment )
{
}

/*
===============
GLimp_CompareModes
===============
*/
static int GLimp_CompareModes( const void *a, const void *b )
{
	const float ASPECT_EPSILON = 0.001f;
	SDL_Rect *modeA = (SDL_Rect *)a;
	SDL_Rect *modeB = (SDL_Rect *)b;
	float aspectA = (float)modeA->w / (float)modeA->h;
	float aspectB = (float)modeB->w / (float)modeB->h;
	int areaA = modeA->w * modeA->h;
	int areaB = modeB->w * modeB->h;
	float aspectDiffA = fabs( aspectA - displayAspect );
	float aspectDiffB = fabs( aspectB - displayAspect );
	float aspectDiffsDiff = aspectDiffA - aspectDiffB;

	if( aspectDiffsDiff > ASPECT_EPSILON )
		return 1;
	else if( aspectDiffsDiff < -ASPECT_EPSILON )
		return -1;
	else
		return areaA - areaB;
}

/*
===============
GLimp_DetectAvailableModes
===============
*/
static void GLimp_DetectAvailableModes(void)
{
	int i, j;
	char buf[ MAX_STRING_CHARS ] = { 0 };
	int numSDLModes;
	SDL_Rect *modes;
	int numModes = 0;

	SDL_DisplayMode windowMode;
	int display = SDL_GetWindowDisplayIndex( SDL_window );
	if( display < 0 )
	{
		ri.Printf( PRINT_WARNING, "Couldn't get window display index, no resolutions detected: %s\n", SDL_GetError() );
		return;
	}
	numSDLModes = SDL_GetNumDisplayModes( display );

	if( SDL_GetWindowDisplayMode( SDL_window, &windowMode ) < 0 || numSDLModes <= 0 )
	{
		ri.Printf( PRINT_WARNING, "Couldn't get window display mode, no resolutions detected: %s\n", SDL_GetError() );
		return;
	}

	modes = SDL_calloc( (size_t)numSDLModes, sizeof( SDL_Rect ) );
	if ( !modes )
	{
		ri.Error( ERR_FATAL, "Out of memory" );
	}

	for( i = 0; i < numSDLModes; i++ )
	{
		SDL_DisplayMode mode;

		if( SDL_GetDisplayMode( display, i, &mode ) < 0 )
			continue;

		if( !mode.w || !mode.h )
		{
			ri.Printf( PRINT_ALL, "Display supports any resolution\n" );
			SDL_free( modes );
			return;
		}

		if( windowMode.format != mode.format )
			continue;

		// SDL can give the same resolution with different refresh rates.
		// Only list resolution once.
		for( j = 0; j < numModes; j++ )
		{
			if( mode.w == modes[ j ].w && mode.h == modes[ j ].h )
				break;
		}

		if( j != numModes )
			continue;

		modes[ numModes ].w = mode.w;
		modes[ numModes ].h = mode.h;
		numModes++;
	}

	if( numModes > 1 )
		qsort( modes, numModes, sizeof( SDL_Rect ), GLimp_CompareModes );

	for( i = 0; i < numModes; i++ )
	{
		const char *newModeString = va( "%ux%u ", modes[ i ].w, modes[ i ].h );

		if( strlen( newModeString ) < (int)sizeof( buf ) - strlen( buf ) )
			Q_strcat( buf, sizeof( buf ), newModeString );
		else
			ri.Printf( PRINT_WARNING, "Skipping mode %ux%u, buffer too small\n", modes[ i ].w, modes[ i ].h );
	}

	if( *buf )
	{
		buf[ strlen( buf ) - 1 ] = 0;
		ri.Printf( PRINT_ALL, "Available modes: '%s'\n", buf );
		ri.Cvar_Set( "r_availableModes", buf );
	}
	SDL_free( modes );
}

/*
===============
OpenGL ES compatibility

GLES has no ClearDepth/DepthRange/DrawBuffer/PolygonMode entry points; these
back the QGL_DESKTOP_1_1_PROCS pointers the shared renderer code still calls.
===============
*/
static void APIENTRY GLimp_GLES_ClearDepth( GLclampd depth ) {
	qglClearDepthf( depth );
}

static void APIENTRY GLimp_GLES_DepthRange( GLclampd near_val, GLclampd far_val ) {
	qglDepthRangef( near_val, far_val );
}

static void APIENTRY GLimp_GLES_DrawBuffer( GLenum mode ) {
	// unsupported
}

static void APIENTRY GLimp_GLES_PolygonMode( GLenum face, GLenum mode ) {
	// unsupported
}

/*
===============
GLimp_GetProcAddresses

Get addresses for OpenGL ES functions, resolved through ANGLE's
eglGetProcAddress rather than SDL_GL_GetProcAddress (which requires a
context SDL itself created).
===============
*/
static qboolean GLimp_GetProcAddresses( void ) {
	qboolean success = qtrue;
	const char *version;

#define GLE( ret, name, ... ) qgl##name = (name##proc *) eglGetProcAddress("gl" #name); \
	if ( qgl##name == NULL ) { \
		ri.Printf( PRINT_ALL, "ERROR: Missing OpenGL function %s\n", "gl" #name ); \
		success = qfalse; \
	}

	GLE(const GLubyte *, GetString, GLenum name)

	if ( !qglGetString ) {
		Com_Error( ERR_FATAL, "glGetString is NULL" );
	}

	version = (const char *)qglGetString( GL_VERSION );

	if ( !version ) {
		Com_Error( ERR_FATAL, "GL_VERSION is NULL" );
	}

	if ( Q_stricmpn( "OpenGL ES", version, 9 ) == 0 ) {
		char profile[6]; // ES, ES-CM, or ES-CL
		sscanf( version, "OpenGL %5s %d.%d", profile, &qglesMajorVersion, &qglesMinorVersion );
	} else {
		sscanf( version, "%d.%d", &qglMajorVersion, &qglMinorVersion );
	}

	if ( !QGLES_VERSION_ATLEAST( 2, 0 ) ) {
		Com_Error( ERR_FATAL, "Unexpected GL_VERSION from ANGLE (%s), OpenGL ES 2.0+ was expected", version );
	}

	// QGL_1_1_PROCS is documented as "OpenGL 1.0/1.1, OpenGL ES 1.0, and
	// OpenGL 3.2 core profile", but it actually also lists a handful of
	// desktop-only compatibility entry points (glCallList, glDrawPixels,
	// glFogi, glLineStipple, glPixelZoom) that don't exist under GLES or a
	// real core profile. This has never surfaced before because Apple's
	// OpenGL.framework returns a valid address for every symbol regardless
	// of the active profile - a loader that actually reflects availability,
	// like ANGLE's, exposes it. GL2 never calls any of these five (the only
	// call sites are dead #if 0 code), so resolve this group best-effort
	// instead of treating a miss as fatal.
#undef GLE
#define GLE( ret, name, ... ) qgl##name = (name##proc *) eglGetProcAddress("gl" #name); \
	if ( qgl##name == NULL ) { \
		ri.Printf( PRINT_DEVELOPER, "Not available under GLES: %s\n", "gl" #name ); \
	}
	QGL_1_1_PROCS;
#undef GLE
#define GLE( ret, name, ... ) qgl##name = (name##proc *) eglGetProcAddress("gl" #name); \
	if ( qgl##name == NULL ) { \
		ri.Printf( PRINT_ALL, "ERROR: Missing OpenGL function %s\n", "gl" #name ); \
		success = qfalse; \
	}

	QGL_ES_1_1_PROCS;
	QGL_1_3_PROCS;
	QGL_1_5_PROCS;
	QGL_2_0_PROCS;

	qglClearDepth = GLimp_GLES_ClearDepth;
	qglDepthRange = GLimp_GLES_DepthRange;
	qglDrawBuffer = GLimp_GLES_DrawBuffer;
	qglPolygonMode = GLimp_GLES_PolygonMode;

	if ( QGLES_VERSION_ATLEAST( 3, 0 ) ) {
		QGL_3_0_PROCS;
	}

#undef GLE

	return success;
}

/*
===============
GLimp_ClearProcAddresses

Clear addresses for OpenGL functions.
===============
*/
static void GLimp_ClearProcAddresses( void ) {
#define GLE( ret, name, ... ) qgl##name = NULL;

	qglMajorVersion = 0;
	qglMinorVersion = 0;
	qglesMajorVersion = 0;
	qglesMinorVersion = 0;

	QGL_1_1_PROCS;
	QGL_1_1_FIXED_FUNCTION_PROCS;
	QGL_DESKTOP_1_1_PROCS;
	QGL_DESKTOP_1_1_FIXED_FUNCTION_PROCS;
	QGL_ES_1_1_PROCS;
	QGL_ES_1_1_FIXED_FUNCTION_PROCS;
	QGL_1_3_PROCS;
	QGL_1_5_PROCS;
	QGL_2_0_PROCS;
	QGL_3_0_PROCS;
	QGL_ARB_occlusion_query_PROCS;
	QGL_ARB_framebuffer_object_PROCS;
	QGL_ARB_vertex_array_object_PROCS;
	QGL_EXT_direct_state_access_PROCS;

	qglActiveTextureARB = NULL;
	qglClientActiveTextureARB = NULL;
	qglMultiTexCoord2fARB = NULL;

	qglLockArraysEXT = NULL;
	qglUnlockArraysEXT = NULL;

#undef GLE
}

/*
===============
GLimp_GetProcAddress / GLimp_ExtensionSupported

See qgl.h for why this indirection exists: tr_extensions.c needs to resolve
a handful of procs and check extensions outside of GLimp_Init's own setup,
and SDL_GL_GetProcAddress/SDL_GL_ExtensionSupported don't work without an
SDL-created GL context. GLimp_ExtensionSupported checks against
glConfig.extensions_string, which GLimp_Init always builds before any code
that might call this.
===============
*/
void *GLimp_GetProcAddress( const char *name ) {
	return (void *)eglGetProcAddress( name );
}

qboolean GLimp_ExtensionSupported( const char *extension ) {
	const char *extensions = glConfig.extensions_string;
	size_t len = strlen( extension );
	const char *p = extensions;

	if ( !extensions ) {
		return qfalse;
	}

	while ( ( p = strstr( p, extension ) ) != NULL ) {
		const char *end = p + len;
		if ( ( p == extensions || p[-1] == ' ' ) && ( *end == ' ' || *end == '\0' ) ) {
			return qtrue;
		}
		p = end;
	}

	return qfalse;
}

/*
===============
GLimp_SetMode
===============
*/
static int GLimp_SetMode(int mode, qboolean fullscreen, qboolean noborder)
{
	const char *glstring;
	int colorBits, depthBits, stencilBits;
	int samples;
	SDL_Surface *icon = NULL;
	Uint32 flags = SDL_WINDOW_HIDDEN | SDL_WINDOW_METAL | SDL_WINDOW_ALLOW_HIGHDPI;
	SDL_DisplayMode desktopMode;
	int display = 0;
	int x = SDL_WINDOWPOS_UNDEFINED, y = SDL_WINDOWPOS_UNDEFINED;
	void *metalLayer;
	int realColorBits[3], realDepthBits, realStencilBits;

	ri.Printf( PRINT_ALL, "Initializing Metal (ANGLE) display\n");

	if ( r_allowResize->integer )
		flags |= SDL_WINDOW_RESIZABLE;

#ifdef USE_ICON
	icon = SDL_CreateRGBSurfaceFrom(
			(void *)CLIENT_WINDOW_ICON.pixel_data,
			CLIENT_WINDOW_ICON.width,
			CLIENT_WINDOW_ICON.height,
			CLIENT_WINDOW_ICON.bytes_per_pixel * 8,
			CLIENT_WINDOW_ICON.bytes_per_pixel * CLIENT_WINDOW_ICON.width,
#ifdef Q3_LITTLE_ENDIAN
			0x000000FF, 0x0000FF00, 0x00FF0000, 0xFF000000
#else
			0xFF000000, 0x00FF0000, 0x0000FF00, 0x000000FF
#endif
			);
#endif

	// If a window exists, note its display index
	if( SDL_window != NULL )
	{
		display = SDL_GetWindowDisplayIndex( SDL_window );
		if( display < 0 )
		{
			ri.Printf( PRINT_DEVELOPER, "SDL_GetWindowDisplayIndex() failed: %s\n", SDL_GetError() );
			display = 0;
		}
	}

	if( SDL_GetDesktopDisplayMode( display, &desktopMode ) == 0 )
	{
		displayAspect = (float)desktopMode.w / (float)desktopMode.h;

		ri.Printf( PRINT_ALL, "Display aspect: %.3f\n", displayAspect );
	}
	else
	{
		Com_Memset( &desktopMode, 0, sizeof( SDL_DisplayMode ) );

		ri.Printf( PRINT_ALL,
				"Cannot determine display aspect, assuming 1.333\n" );
	}

	ri.Printf (PRINT_ALL, "...setting mode %d:", mode );

	if (mode == -2 || fullscreen)
	{
		// Use desktop video resolution. This also applies whenever fullscreen is
		// requested (regardless of which resolution mode was actually selected):
		// fullscreen is always presented via SDL_WINDOW_FULLSCREEN_DESKTOP (a
		// borderless window sized to the desktop) rather than an exclusive
		// display mode switch, since real mode switching to a non-native
		// resolution is unreliable on macOS.
		if( desktopMode.h > 0 )
		{
			glConfig.vidWidth = desktopMode.w;
			glConfig.vidHeight = desktopMode.h;
		}
		else
		{
			glConfig.vidWidth = 640;
			glConfig.vidHeight = 480;
			ri.Printf( PRINT_ALL,
					"Cannot determine display resolution, assuming 640x480\n" );
		}

		glConfig.windowAspect = (float)glConfig.vidWidth / (float)glConfig.vidHeight;
	}
	else if ( !R_GetModeInfo( &glConfig.vidWidth, &glConfig.vidHeight, &glConfig.windowAspect, mode ) )
	{
		ri.Printf( PRINT_ALL, " invalid mode\n" );
		SDL_FreeSurface( icon );
		return RSERR_INVALID_MODE;
	}
	ri.Printf( PRINT_ALL, " %d %d\n", glConfig.vidWidth, glConfig.vidHeight);

	// Center window
	if( r_centerWindow->integer && !fullscreen )
	{
		x = ( desktopMode.w / 2 ) - ( glConfig.vidWidth / 2 );
		y = ( desktopMode.h / 2 ) - ( glConfig.vidHeight / 2 );
	}

	// Destroy existing state if it exists
	GLimp_ClearProcAddresses();
	Metal_DestroySurfaceAndContext();

	if( metalView != NULL )
	{
		SDL_Metal_DestroyView( metalView );
		metalView = NULL;
	}

	if( SDL_window != NULL )
	{
		SDL_GetWindowPosition( SDL_window, &x, &y );
		ri.Printf( PRINT_DEVELOPER, "Existing window at %dx%d before being destroyed\n", x, y );
		SDL_DestroyWindow( SDL_window );
		SDL_window = NULL;
	}

	if( fullscreen )
	{
		flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
		glConfig.isFullscreen = qtrue;
	}
	else
	{
		if( noborder )
			flags |= SDL_WINDOW_BORDERLESS;

		glConfig.isFullscreen = qfalse;
	}

	colorBits = r_colorbits->value;
	if ((!colorBits) || (colorBits >= 32))
		colorBits = 24;

	depthBits = r_depthbits->value ? r_depthbits->value : 24;
	stencilBits = r_stencilbits->value;
	samples = r_ext_multisample->value;

	if( r_stereoEnabled->integer )
	{
		ri.Printf( PRINT_ALL, "...stereo rendering is not supported by the Metal renderer, ignoring r_stereoEnabled\n" );
	}
	glConfig.stereoEnabled = qfalse;

	if ( !Metal_InitDisplay() )
	{
		SDL_FreeSurface( icon );
		return RSERR_INVALID_MODE;
	}

	SDL_window = SDL_CreateWindow( CLIENT_WINDOW_TITLE, x, y,
			glConfig.vidWidth, glConfig.vidHeight, flags );
	if ( SDL_window == NULL )
	{
		ri.Printf( PRINT_ALL, "SDL_CreateWindow failed: %s\n", SDL_GetError() );
		SDL_FreeSurface( icon );
		return RSERR_INVALID_MODE;
	}

	metalView = SDL_Metal_CreateView( SDL_window );
	if ( metalView == NULL )
	{
		ri.Printf( PRINT_ALL, "SDL_Metal_CreateView failed: %s\n", SDL_GetError() );
		SDL_DestroyWindow( SDL_window );
		SDL_window = NULL;
		SDL_FreeSurface( icon );
		return RSERR_INVALID_MODE;
	}

	metalLayer = SDL_Metal_GetLayer( metalView );

	if ( !Metal_CreateSurfaceAndContext( metalLayer, depthBits, stencilBits, samples ) )
	{
		SDL_Metal_DestroyView( metalView );
		metalView = NULL;
		SDL_DestroyWindow( SDL_window );
		SDL_window = NULL;
		SDL_FreeSurface( icon );
		return RSERR_INVALID_MODE;
	}

	if ( !GLimp_GetProcAddresses() )
	{
		ri.Printf( PRINT_ALL, "GLimp_GetProcAddresses() failed\n" );
		GLimp_ClearProcAddresses();
		Metal_DestroySurfaceAndContext();
		SDL_Metal_DestroyView( metalView );
		metalView = NULL;
		SDL_DestroyWindow( SDL_window );
		SDL_window = NULL;
		SDL_FreeSurface( icon );
		return RSERR_INVALID_MODE;
	}

	SDL_SetWindowIcon( SDL_window, icon );
	SDL_FreeSurface( icon );

	qglClearColor( 0, 0, 0, 1 );
	qglClear( GL_COLOR_BUFFER_BIT );
	eglSwapBuffers( eglDisplay, eglSurface );

	if ( eglSwapInterval( eglDisplay, r_swapInterval->integer ) == EGL_FALSE )
	{
		ri.Printf( PRINT_DEVELOPER, "eglSwapInterval failed: 0x%x\n", eglGetError() );
	}

	eglGetConfigAttrib( eglDisplay, eglConfig, EGL_RED_SIZE, &realColorBits[0] );
	eglGetConfigAttrib( eglDisplay, eglConfig, EGL_GREEN_SIZE, &realColorBits[1] );
	eglGetConfigAttrib( eglDisplay, eglConfig, EGL_BLUE_SIZE, &realColorBits[2] );
	eglGetConfigAttrib( eglDisplay, eglConfig, EGL_DEPTH_SIZE, &realDepthBits );
	eglGetConfigAttrib( eglDisplay, eglConfig, EGL_STENCIL_SIZE, &realStencilBits );

	glConfig.colorBits = realColorBits[0] + realColorBits[1] + realColorBits[2];
	glConfig.depthBits = realDepthBits;
	glConfig.stencilBits = realStencilBits;

	ri.Printf( PRINT_ALL, "Using %d color bits, %d depth, %d stencil display.\n",
			glConfig.colorBits, glConfig.depthBits, glConfig.stencilBits );

	SDL_ShowWindow( SDL_window );

	GLimp_DetectAvailableModes();

	glstring = (char *) qglGetString (GL_RENDERER);
	ri.Printf( PRINT_ALL, "GL_RENDERER: %s\n", glstring );

	return RSERR_OK;
}

/*
===============
GLimp_StartDriverAndSetMode
===============
*/
static qboolean GLimp_StartDriverAndSetMode(int mode, qboolean fullscreen, qboolean noborder)
{
	rserr_t err;

	if (!SDL_WasInit(SDL_INIT_VIDEO))
	{
		const char *driverName;

		if (SDL_Init(SDL_INIT_VIDEO) != 0)
		{
			ri.Printf( PRINT_ALL, "SDL_Init( SDL_INIT_VIDEO ) FAILED (%s)\n", SDL_GetError());
			return qfalse;
		}

		driverName = SDL_GetCurrentVideoDriver( );
		ri.Printf( PRINT_ALL, "SDL using driver \"%s\"\n", driverName );
		ri.Cvar_Set( "r_sdlDriver", driverName );
	}

	if (fullscreen && ri.Cvar_VariableIntegerValue( "in_nograb" ) )
	{
		ri.Printf( PRINT_ALL, "Fullscreen not allowed with in_nograb 1\n");
		ri.Cvar_Set( "r_fullscreen", "0" );
		r_fullscreen->modified = qfalse;
		fullscreen = qfalse;
	}

	err = GLimp_SetMode(mode, fullscreen, noborder);

	switch ( err )
	{
		case RSERR_INVALID_FULLSCREEN:
			ri.Printf( PRINT_ALL, "...WARNING: fullscreen unavailable in this mode\n" );
			return qfalse;
		case RSERR_INVALID_MODE:
			ri.Printf( PRINT_ALL, "...WARNING: could not set the given mode (%d)\n", mode );
			return qfalse;
		default:
			break;
	}

	return qtrue;
}

/*
===============
GLimp_InitExtensions
===============
*/
static void GLimp_InitExtensions( void )
{
	if ( !r_allowExtensions->integer )
	{
		ri.Printf( PRINT_ALL, "* IGNORING OPENGL EXTENSIONS *\n" );
		return;
	}

	ri.Printf( PRINT_ALL, "Initializing OpenGL extensions\n" );

	glConfig.textureCompression = TC_NONE;

	// GL_EXT_texture_compression_s3tc
	if ( GLimp_ExtensionSupported( "GL_EXT_texture_compression_s3tc" ) )
	{
		if ( r_ext_compressed_textures->value )
		{
			glConfig.textureCompression = TC_S3TC_ARB;
			ri.Printf( PRINT_ALL, "...using GL_EXT_texture_compression_s3tc\n" );
		}
		else
		{
			ri.Printf( PRINT_ALL, "...ignoring GL_EXT_texture_compression_s3tc\n" );
		}
	}
	else
	{
		ri.Printf( PRINT_ALL, "...GL_EXT_texture_compression_s3tc not found\n" );
	}

	textureFilterAnisotropic = qfalse;
	if ( GLimp_ExtensionSupported( "GL_EXT_texture_filter_anisotropic" ) )
	{
		if ( r_ext_texture_filter_anisotropic->integer ) {
			qglGetIntegerv( GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT, (GLint *)&maxAnisotropy );
			if ( maxAnisotropy <= 0 ) {
				ri.Printf( PRINT_ALL, "...GL_EXT_texture_filter_anisotropic not properly supported!\n" );
				maxAnisotropy = 0;
			}
			else
			{
				ri.Printf( PRINT_ALL, "...using GL_EXT_texture_filter_anisotropic (max: %i)\n", maxAnisotropy );
				textureFilterAnisotropic = qtrue;
			}
		}
		else
		{
			ri.Printf( PRINT_ALL, "...ignoring GL_EXT_texture_filter_anisotropic\n" );
		}
	}
	else
	{
		ri.Printf( PRINT_ALL, "...GL_EXT_texture_filter_anisotropic not found\n" );
	}

	// Edge-clamp sampling is always available on GLES (core since GLES 1.0/2.0).
	haveClampToEdge = qtrue;
	ri.Printf( PRINT_ALL, "...using GL_SGIS_texture_edge_clamp (core on GLES)\n" );
}

#define R_MODE_FALLBACK 3 // 640 * 480

/*
===============
GLimp_Init

This routine is responsible for initializing the OS specific portions
of OpenGL
===============
*/
void GLimp_Init( qboolean fixedFunction )
{
	ri.Printf( PRINT_DEVELOPER, "Glimp_Init( )\n" );

	if ( fixedFunction ) {
		Com_Error( ERR_FATAL, "The Metal renderer does not support the fixed-function pipeline" );
	}

	r_sdlDriver = ri.Cvar_Get( "r_sdlDriver", "", CVAR_ROM );
	r_allowResize = ri.Cvar_Get( "r_allowResize", "0", CVAR_ARCHIVE | CVAR_LATCH );
	r_centerWindow = ri.Cvar_Get( "r_centerWindow", "0", CVAR_ARCHIVE | CVAR_LATCH );

	if( ri.Cvar_VariableIntegerValue( "com_abnormalExit" ) )
	{
		ri.Cvar_Set( "r_mode", va( "%d", R_MODE_FALLBACK ) );
		ri.Cvar_Set( "r_fullscreen", "0" );
		ri.Cvar_Set( "r_centerWindow", "0" );
		ri.Cvar_Set( "com_abnormalExit", "0" );
	}

	ri.Sys_GLimpInit( );

	// Create the window and set up the context
	if(GLimp_StartDriverAndSetMode(r_mode->integer, r_fullscreen->integer, r_noborder->integer))
		goto success;

	// Try again, this time in a platform specific "safe mode"
	ri.Sys_GLimpSafeInit( );

	if(GLimp_StartDriverAndSetMode(r_mode->integer, r_fullscreen->integer, qfalse))
		goto success;

	// Finally, try the default screen resolution
	if( r_mode->integer != R_MODE_FALLBACK )
	{
		ri.Printf( PRINT_ALL, "Setting r_mode %d failed, falling back on r_mode %d\n",
				r_mode->integer, R_MODE_FALLBACK );

		if(GLimp_StartDriverAndSetMode(R_MODE_FALLBACK, qfalse, qfalse))
			goto success;
	}

	// Nothing worked, give up
	ri.Error( ERR_FATAL, "GLimp_Init() - could not load Metal (ANGLE) subsystem" );

success:
	// These values force the UI to disable driver selection
	glConfig.driverType = GLDRV_ICD;
	glConfig.hardwareType = GLHW_GENERIC;

	// Only using SDL_SetWindowBrightness to determine if hardware gamma is supported
	glConfig.deviceSupportsGamma = !r_ignorehwgamma->integer &&
		SDL_SetWindowBrightness( SDL_window, 1.0f ) >= 0;

	// get our config strings
	Q_strncpyz( glConfig.vendor_string, (char *) qglGetString (GL_VENDOR), sizeof( glConfig.vendor_string ) );
	Q_strncpyz( glConfig.renderer_string, (char *) qglGetString (GL_RENDERER), sizeof( glConfig.renderer_string ) );
	if (*glConfig.renderer_string && glConfig.renderer_string[strlen(glConfig.renderer_string) - 1] == '\n')
		glConfig.renderer_string[strlen(glConfig.renderer_string) - 1] = 0;
	Q_strncpyz( glConfig.version_string, (char *) qglGetString (GL_VERSION), sizeof( glConfig.version_string ) );

	// manually create extension list, same as a GL3+ core context
	if ( qglGetStringi )
	{
		int i, numExtensions, extensionLength, listLength;
		const char *extension;

		qglGetIntegerv( GL_NUM_EXTENSIONS, &numExtensions );
		listLength = 0;

		for ( i = 0; i < numExtensions; i++ )
		{
			extension = (char *) qglGetStringi( GL_EXTENSIONS, i );
			extensionLength = strlen( extension );

			if ( ( listLength + extensionLength + 1 ) >= sizeof( glConfig.extensions_string ) )
				break;

			if ( i > 0 ) {
				Q_strcat( glConfig.extensions_string, sizeof( glConfig.extensions_string ), " " );
				listLength++;
			}

			Q_strcat( glConfig.extensions_string, sizeof( glConfig.extensions_string ), extension );
			listLength += extensionLength;
		}
	}
	else
	{
		Q_strncpyz( glConfig.extensions_string, (char *) qglGetString (GL_EXTENSIONS), sizeof( glConfig.extensions_string ) );
	}

	// initialize extensions
	GLimp_InitExtensions();

	ri.Cvar_Get( "r_availableModes", "", CVAR_ROM );

	// This depends on SDL_INIT_VIDEO, hence having it here
	ri.IN_Init( SDL_window );
}

/*
===============
GLimp_EndFrame

Responsible for doing a swapbuffers
===============
*/
void GLimp_EndFrame( void )
{
	// don't flip if drawing to front buffer
	if ( Q_stricmp( r_drawBuffer->string, "GL_FRONT" ) != 0 )
	{
		eglSwapBuffers( eglDisplay, eglSurface );
	}

	if( r_fullscreen->modified )
	{
		int         fullscreen;
		qboolean    needToToggle;
		qboolean    sdlToggled = qfalse;

		// Find out the current state
		fullscreen = !!( SDL_GetWindowFlags( SDL_window ) & SDL_WINDOW_FULLSCREEN );

		if( r_fullscreen->integer && ri.Cvar_VariableIntegerValue( "in_nograb" ) )
		{
			ri.Printf( PRINT_ALL, "Fullscreen not allowed with in_nograb 1\n");
			ri.Cvar_Set( "r_fullscreen", "0" );
			r_fullscreen->modified = qfalse;
		}

		// Is the state we want different from the current state?
		needToToggle = !!r_fullscreen->integer != fullscreen;

		if( needToToggle )
		{
			sdlToggled = SDL_SetWindowFullscreen( SDL_window,
				r_fullscreen->integer ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0 ) >= 0;

			// SDL_WM_ToggleFullScreen didn't work, so do it the slow way
			if( !sdlToggled )
				ri.Cmd_ExecuteText(EXEC_APPEND, "vid_restart\n");

			ri.IN_Restart( );
		}

		r_fullscreen->modified = qfalse;
	}
}

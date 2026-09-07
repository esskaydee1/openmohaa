/*
===========================================================================
renderer_metalrt - lifecycle: GetRefAPI, window/device/swapchain setup,
Shutdown, BeginFrame/EndFrame.

Session 1 scope only: open a window, stand up a native Metal device +
command queue + swapchain, and present a solid clear color every frame.
No real scene content yet - every other refexport_t function is a loud
stub (see rt_stubs.cpp) until a later session implements it for real.
===========================================================================
*/
#include "rt_local.h"

#ifdef USE_INTERNAL_SDL_HEADERS
#	include "SDL.h"
#	include "SDL_metal.h"
#else
#	include <SDL.h>
#	include <SDL_metal.h>
#endif

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

refimport_t ri;
glconfig_t rtGlConfig;

namespace {

SDL_Window *rtWindow = NULL;
SDL_MetalView rtMetalView = NULL;

id<MTLDevice> rtDevice = nil;
id<MTLCommandQueue> rtQueue = nil;
CAMetalLayer *rtLayer = nil;

id<CAMetalDrawable> rtCurrentDrawable = nil;
id<MTLCommandBuffer> rtCurrentCommandBuffer = nil;

// Deliberately fixed for session 1 - real video-mode selection (r_mode,
// r_fullscreen, custom resolution, matching sdl_glimp.c/sdl_metalimp.c's
// mode-negotiation logic) is its own follow-up session, not bundled into
// getting the device/swapchain/present loop proven correct first.
const int RT_INITIAL_WIDTH = 1280;
const int RT_INITIAL_HEIGHT = 800;

bool RT_InitWindowAndDevice( void )
{
	if ( !SDL_WasInit( SDL_INIT_VIDEO ) )
	{
		if ( SDL_Init( SDL_INIT_VIDEO ) != 0 )
		{
			ri.Printf( PRINT_ERROR, "renderer_metalrt: SDL_Init(SDL_INIT_VIDEO) failed: %s\n", SDL_GetError() );
			return false;
		}
	}

	Uint32 flags = SDL_WINDOW_METAL | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_HIDDEN;
	rtWindow = SDL_CreateWindow( "OpenMoHAA (renderer_metalrt)",
		SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
		RT_INITIAL_WIDTH, RT_INITIAL_HEIGHT, flags );
	if ( rtWindow == NULL )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: SDL_CreateWindow failed: %s\n", SDL_GetError() );
		return false;
	}

	rtMetalView = SDL_Metal_CreateView( rtWindow );
	if ( rtMetalView == NULL )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: SDL_Metal_CreateView failed: %s\n", SDL_GetError() );
		return false;
	}

	rtLayer = (__bridge CAMetalLayer *)SDL_Metal_GetLayer( rtMetalView );

	rtDevice = MTLCreateSystemDefaultDevice();
	if ( rtDevice == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: MTLCreateSystemDefaultDevice returned nil\n" );
		return false;
	}

	rtQueue = [rtDevice newCommandQueue];
	if ( rtQueue == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: newCommandQueue returned nil\n" );
		return false;
	}

	rtLayer.device = rtDevice;
	rtLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;

	int drawableW = 0, drawableH = 0;
	SDL_Metal_GetDrawableSize( rtWindow, &drawableW, &drawableH );
	rtLayer.drawableSize = CGSizeMake( drawableW, drawableH );

	// Only show the window once the layer is fully configured (device,
	// pixel format, drawable size) - matches the working order used
	// earlier this session for the ANGLE-backed renderer_metal, rather
	// than showing the window first and configuring the layer after.
	SDL_ShowWindow( rtWindow );

	Com_Memset( &rtGlConfig, 0, sizeof( rtGlConfig ) );
	Q_strncpyz( rtGlConfig.renderer_string, [rtDevice.name UTF8String], sizeof( rtGlConfig.renderer_string ) );
	Q_strncpyz( rtGlConfig.vendor_string, "Apple", sizeof( rtGlConfig.vendor_string ) );
	Q_strncpyz( rtGlConfig.version_string, "Metal (native, renderer_metalrt)", sizeof( rtGlConfig.version_string ) );
	rtGlConfig.vidWidth = RT_INITIAL_WIDTH;
	rtGlConfig.vidHeight = RT_INITIAL_HEIGHT;
	rtGlConfig.windowAspect = (float)RT_INITIAL_WIDTH / (float)RT_INITIAL_HEIGHT;
	rtGlConfig.colorBits = 32;
	// No depth/stencil buffer exists yet this session - report honestly
	// rather than claim a buffer that isn't there.
	rtGlConfig.depthBits = 0;
	rtGlConfig.stencilBits = 0;
	rtGlConfig.driverType = GLDRV_ICD;
	rtGlConfig.hardwareType = GLHW_GENERIC;
	rtGlConfig.isFullscreen = qfalse;
	rtGlConfig.textureCompression = TC_NONE;

	ri.Printf( PRINT_ALL, "renderer_metalrt: device \"%s\", window %dx%d, drawable %dx%d\n",
		[rtDevice.name UTF8String], RT_INITIAL_WIDTH, RT_INITIAL_HEIGHT, drawableW, drawableH );

	return true;
}

void RT_ShutdownWindowAndDevice( void )
{
	rtCurrentCommandBuffer = nil;
	rtCurrentDrawable = nil;

	rtQueue = nil;
	rtDevice = nil;
	rtLayer = nil;

	if ( rtMetalView != NULL )
	{
		SDL_Metal_DestroyView( rtMetalView );
		rtMetalView = NULL;
	}

	if ( rtWindow != NULL )
	{
		SDL_DestroyWindow( rtWindow );
		rtWindow = NULL;
	}

	SDL_QuitSubSystem( SDL_INIT_VIDEO );
}

} // namespace

/*
===============
RE_Shutdown
===============
*/
static void RE_Shutdown( qboolean destroyWindow )
{
	ri.Printf( PRINT_ALL, "renderer_metalrt: RE_Shutdown( %i )\n", destroyWindow );

	if ( destroyWindow )
	{
		RT_ShutdownWindowAndDevice();
	}
}

/*
===============
RE_BeginRegistration

Session 1 has nothing to register yet - just hand back the real
glconfig_t the client needs for UI layout.
===============
*/
static void RE_BeginRegistration( glconfig_t *config )
{
	*config = rtGlConfig;
}

/*
===============
RE_EndRegistration

Nothing was registered this session, so nothing to touch here yet.
Not a stub: this is a complete, correct implementation of "do the
end-of-registration work," which today is none.
===============
*/
static void RE_EndRegistration( void )
{
}

/*
===============
RE_BeginFrame / RE_EndFrame

The whole point of session 1: prove the swapchain/present loop is
correct before any real scene content exists. Acquires a drawable and
clears it to a solid, distinctive color; RE_EndFrame presents it.
===============
*/
static void RE_BeginFrame( stereoFrame_t stereoFrame )
{
	rtCurrentDrawable = [rtLayer nextDrawable];
	if ( rtCurrentDrawable == nil )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: nextDrawable returned nil\n" );
		return;
	}

	rtCurrentCommandBuffer = [rtQueue commandBuffer];

	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = rtCurrentDrawable.texture;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	// A deliberately distinctive dark teal - not black, not any color an
	// unrelated bug (e.g. an uninitialized buffer) would plausibly produce -
	// so a live session can tell at a glance that this is renderer_metalrt
	// actually presenting, not a black window from something else failing.
	pass.colorAttachments[0].clearColor = MTLClearColorMake( 0.0, 0.15, 0.2, 1.0 );

	id<MTLRenderCommandEncoder> encoder = [rtCurrentCommandBuffer renderCommandEncoderWithDescriptor:pass];
	[encoder endEncoding];
}

static void RE_EndFrame( int *frontEndMsec, int *backEndMsec )
{
	if ( rtCurrentCommandBuffer != nil && rtCurrentDrawable != nil )
	{
		[rtCurrentCommandBuffer presentDrawable:rtCurrentDrawable];
		[rtCurrentCommandBuffer commit];
	}

	rtCurrentCommandBuffer = nil;
	rtCurrentDrawable = nil;

	// No timing instrumentation yet.
	if ( frontEndMsec != NULL )
		*frontEndMsec = 0;
	if ( backEndMsec != NULL )
		*backEndMsec = 0;
}

// Forward declaration - the rest of refexport_t's ~78 functions are
// assigned by RT_InitStubs (rt_stubs.cpp), keeping the loud-stub
// boilerplate out of this file.
void RT_InitStubs( refexport_t *re );

/*
@@@@@@@@@@@@@@@@@@@@@
GetRefAPI

The only function actually exported at the linker level. If the module
can't init to a valid rendering state, NULL is returned - all renderer
setup (window, device, swapchain) happens synchronously here, before
returning, matching how GetRefAPI works in the other renderers.
@@@@@@@@@@@@@@@@@@@@@
*/
#ifdef USE_RENDERER_DLOPEN
extern "C" Q_EXPORT refexport_t *QDECL GetRefAPI( int apiVersion, refimport_t *rimp )
#else
extern "C" refexport_t *GetRefAPI( int apiVersion, refimport_t *rimp )
#endif
{
	static refexport_t re;

	ri = *rimp;

	Com_Memset( &re, 0, sizeof( re ) );

	if ( apiVersion != REF_API_VERSION )
	{
		ri.Printf( PRINT_ALL, "renderer_metalrt: Mismatched REF_API_VERSION: expected %i, got %i\n",
			REF_API_VERSION, apiVersion );
		return NULL;
	}

	ri.Printf( PRINT_ALL, "----- renderer_metalrt R_Init -----\n" );

	if ( !RT_InitWindowAndDevice() )
	{
		ri.Printf( PRINT_ALL, "renderer_metalrt: failed to initialize window/device\n" );
		return NULL;
	}

	// Lifecycle + frame: real, minimal implementations (this session's work).
	re.Shutdown = RE_Shutdown;
	re.BeginRegistration = RE_BeginRegistration;
	re.EndRegistration = RE_EndRegistration;
	re.BeginFrame = RE_BeginFrame;
	re.EndFrame = RE_EndFrame;

	// Everything else: loud stubs until a later session implements them.
	RT_InitStubs( &re );

	ri.Printf( PRINT_ALL, "----- finished renderer_metalrt R_Init -----\n" );

	return &re;
}

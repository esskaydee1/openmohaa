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
id<MTLRenderCommandEncoder> rtCurrentEncoder = nil;

// Fixed-size depth buffer matching the initial window/drawable size (see
// RT_INITIAL_WIDTH/HEIGHT below) - like real video-mode handling, resize
// support is a follow-up session, not bundled into "add a depth buffer."
id<MTLTexture> rtDepthTexture = nil;

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
	// Explicit, not just relying on CAMetalLayer's default: session 18's
	// FPS-gap investigation confirmed nextDrawable's vsync blocking (via
	// this) is the actual frame pacing mechanism, not GL's r_swapinterval
	// equivalent - com_speeds profiling showed real render frontend/
	// backend cost is ~0ms every frame, so this deliberately paces to
	// the display, matching normal smooth-gameplay expectations.
	rtLayer.displaySyncEnabled = YES;

	int drawableW = 0, drawableH = 0;
	SDL_Metal_GetDrawableSize( rtWindow, &drawableW, &drawableH );
	rtLayer.drawableSize = CGSizeMake( drawableW, drawableH );

	MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
	                                                                                       width:drawableW
	                                                                                      height:drawableH
	                                                                                   mipmapped:NO];
	depthDesc.usage = MTLTextureUsageRenderTarget;
	depthDesc.storageMode = MTLStorageModePrivate;
	rtDepthTexture = [rtDevice newTextureWithDescriptor:depthDesc];

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
	rtGlConfig.depthBits = 32; // MTLPixelFormatDepth32Float
	// No stencil buffer exists yet - report honestly rather than claim
	// one that isn't there.
	rtGlConfig.stencilBits = 0;
	rtGlConfig.driverType = GLDRV_ICD;
	rtGlConfig.hardwareType = GLHW_GENERIC;
	rtGlConfig.isFullscreen = qfalse;
	rtGlConfig.textureCompression = TC_NONE;

	ri.Printf( PRINT_ALL, "renderer_metalrt: device \"%s\", window %dx%d, drawable %dx%d\n",
		[rtDevice.name UTF8String], RT_INITIAL_WIDTH, RT_INITIAL_HEIGHT, drawableW, drawableH );

	// sdl_glimp.c/sdl_metalimp.c both do this right after their window is
	// ready - without it, sdl_input.c's SDL_window stays NULL and IN_Frame
	// eventually dereferences it (crashes the first time gameplay actually
	// reaches the mouse-focus check, not on frame 1 - see CLAUDE.md status
	// log for how this was root-caused).
	ri.IN_Init( rtWindow );

	return true;
}

void RT_ShutdownWindowAndDevice( void )
{
	ri.IN_Shutdown();

	rtCurrentCommandBuffer = nil;
	rtCurrentDrawable = nil;
	rtDepthTexture = nil;

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

id<MTLDevice> RT_GetDevice( void )
{
	return rtDevice;
}

id<MTLRenderCommandEncoder> RT_GetCurrentEncoder( void )
{
	return rtCurrentEncoder;
}

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

Acquires a drawable, clears it, and opens a render command encoder that
stays open for the rest of the frame - RT_GetCurrentEncoder() (rt_local.h)
lets other files (rt_image.mm's DrawStretchPic) encode draw calls into
it. RE_EndFrame closes the encoder and presents.
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
	// Anything drawn this frame (DrawStretchPic etc.) paints over it.
	pass.colorAttachments[0].clearColor = MTLClearColorMake( 0.0, 0.15, 0.2, 1.0 );

	pass.depthAttachment.texture = rtDepthTexture;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.storeAction = MTLStoreActionDontCare;
	pass.depthAttachment.clearDepth = 1.0;

	rtCurrentEncoder = [rtCurrentCommandBuffer renderCommandEncoderWithDescriptor:pass];
}

static void RE_EndFrame( int *frontEndMsec, int *backEndMsec )
{
	if ( rtCurrentEncoder != nil )
	{
		[rtCurrentEncoder endEncoding];
		rtCurrentEncoder = nil;
	}

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

// Forward declarations - the rest of refexport_t's functions are
// assigned by RT_InitStubs (rt_stubs.cpp, loud stubs) and
// RT_InitImageFunctions (rt_image.mm, real RegisterShader/
// RegisterShaderNoMip/DrawStretchPic), keeping that boilerplate out of
// this file.
void RT_InitStubs( refexport_t *re );
void RT_InitImageFunctions( refexport_t *re );
void RT_InitSceneFunctions( refexport_t *re );
void RT_InitWorldFunctions( refexport_t *re );
void RT_InitFontFunctions( refexport_t *re );

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

	// Real image registration + 2D drawing (Phase 1 session 2).
	RT_InitImageFunctions( &re );

	// Real model registration + 3D scene submission (Phase 1 session 3).
	RT_InitSceneFunctions( &re );

	// Real world/BSP geometry (Phase 1 session 4).
	RT_InitWorldFunctions( &re );

	// Real font loading/text rendering (Phase 1 session 12).
	RT_InitFontFunctions( &re );

	ri.Printf( PRINT_ALL, "----- finished renderer_metalrt R_Init -----\n" );

	return &re;
}

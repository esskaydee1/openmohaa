/*
===========================================================================
renderer_metalrt - Phase 1 session 2: real shader/image registration and
2D pic drawing (RegisterShader, RegisterShaderNoMip, DrawStretchPic).

Deliberately simple for now: RegisterShader treats its name as a direct
image file (trying common extensions if none is given), not a .shader
script - that parser is Phase 2's job (docs/ARCHITECTURE.md's material
translation layer). This gets real textures on screen via the same
generic, renderer-agnostic image decoders (tr_image_tga.c etc.) the
other renderers use, which never touch GL/qgl themselves.
===========================================================================
*/
#include "rt_local.h"

// Renderer-agnostic image decoders (code/renderercommon/), pure
// filesystem + memory (ri.FS_ReadFile/ri.Malloc/ri.Error) - no GL calls,
// safe to use unchanged from a native Metal renderer. TGA/BMP/PCX are
// plain C, no external library (session 2). JPG (session 15) needs
// libjpeg - always the vendored thirdparty/jpeg-9f source
// (cmake/renderer_metalrt.cmake), not a system libjpeg, to keep this
// renderer's build self-contained; R_LoadJPG already outputs RGBA
// (4 bytes/pixel, alpha forced to 255) exactly like the other three
// loaders, so it's a drop-in addition to RT_LoadImageFile below with no
// changes needed anywhere else in the pipeline. PNG (session 16) needs
// puff.c's inflate, which - like tga/bmp/pcx - is pure in-tree C with no
// external library, so R_LoadPNG is just as much a drop-in addition.
extern "C" {
void R_LoadTGA( const char *name, byte **pic, int *width, int *height );
void R_LoadBMP( const char *name, byte **pic, int *width, int *height );
void R_LoadPCX( const char *name, byte **pic, int *width, int *height );
void R_LoadJPG( const char *name, byte **pic, int *width, int *height );
void R_LoadPNG( const char *name, byte **pic, int *width, int *height );
}

namespace {

struct RTVertex2D {
	float position[2]; // NDC, already projected on the CPU side
	float texcoord[2];
};

struct rtImage_t {
	id<MTLTexture> texture;
	int width;
	int height;
	char name[MAX_QPATH];
	// Session 13: classified from the resolved .shader's blendfunc line,
	// if any (RT_BLEND_OPAQUE for a direct-image-file resolution, which
	// never has one). Cached here rather than re-parsed per use, since
	// the same shader-script scan that finds a texture path already
	// visits any blendfunc line in the same block.
	rtBlendMode_t blendMode;
};

#define MAX_RT_IMAGES 1024
rtImage_t rtImages[MAX_RT_IMAGES]; // index 0 unused - handle 0 means "invalid"
int numRtImages = 0;

id<MTLRenderPipelineState> rtPipeline2D = nil;
id<MTLSamplerState> rtSampler2D = nil;

// Set by Set2DWindow, read by DrawStretchPic. uiwidget.cpp (UIWidget::set2D)
// calls this once per widget with a viewport rect (vx/vy/vw/vh, real pixels,
// Y-down from the top like the rest of this engine's 2D convention) and a
// local coordinate origin (left/right/bottom/top) that widget's own
// DrawStretchPic calls are expressed in - every widget draws itself at
// local (0,0,width,height), relying entirely on this mapping to land at
// its real screen position. Before this was implemented, every widget's
// (0,0) was misread as absolute screen-pixel (0,0), so every menu button
// drew stacked at the same spot instead of its own place in the layout.
// Defaults to an identity mapping (matches the engine's own full-screen
// default, e.g. GL1's RB_SetGL2D) so any draw call issued before the first
// real Set2DWindow behaves exactly as it did before this existed.
struct {
	float vx, vy, vw, vh;
	float left, right, bottom, top;
} rt2DWindow = { 0, 0, 0, 0, 0, 0, 0, 0 };
bool rt2DWindowInitialized = false;

void RT_EnsureDefault2DWindow( void )
{
	if ( rt2DWindowInitialized )
		return;
	rt2DWindow.vx = 0.0f;
	rt2DWindow.vy = 0.0f;
	rt2DWindow.vw = (float)rtGlConfig.vidWidth;
	rt2DWindow.vh = (float)rtGlConfig.vidHeight;
	rt2DWindow.left = 0.0f;
	rt2DWindow.right = (float)rtGlConfig.vidWidth;
	rt2DWindow.top = 0.0f;
	rt2DWindow.bottom = (float)rtGlConfig.vidHeight;
	rt2DWindowInitialized = true;
}

void RT_MapLocalToScreen( float lx, float ly, float *outX, float *outY )
{
	float rangeX = rt2DWindow.right - rt2DWindow.left;
	float rangeY = rt2DWindow.bottom - rt2DWindow.top;
	float fracX = ( rangeX != 0.0f ) ? ( lx - rt2DWindow.left ) / rangeX : 0.0f;
	float fracY = ( rangeY != 0.0f ) ? ( ly - rt2DWindow.top ) / rangeY : 0.0f;
	*outX = rt2DWindow.vx + fracX * rt2DWindow.vw;

	// rt2DWindow.vy follows OpenGL's bottom-up glViewport convention, not
	// Metal's top-down one - UIWidget::set2D (code/uilib/uiwidget.cpp)
	// computes it as "vidHeight - (widget's local bottom edge)" because
	// that's what a real qglViewport call needs, and Set2DWindow's ABI
	// carries that straight through unchanged. Using vy directly as if
	// it were already a top-down screen Y (session 5's original bug)
	// only LOOKED correct for widgets that span nearly the full window
	// height (vy≈0) or for symmetric pairs compared only against each
	// other (the pause menu's two buttons, both wrong by the same
	// amount, so their relative spread still looked "fixed") - it was
	// never actually right. The true top-down top edge of the viewport
	// is vidHeight - (vy + vh); convert once here, then apply the
	// fraction the same way X does.
	float metalTopY = (float)rtGlConfig.vidHeight - ( rt2DWindow.vy + rt2DWindow.vh );
	*outY = metalTopY + fracY * rt2DWindow.vh;
}

const char *rtShaderSource2D =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct VertexIn { float2 position; float2 texcoord; };\n"
	"struct VertexOut { float4 position [[position]]; float2 texcoord; };\n"
	"vertex VertexOut rt_vertex_2d(uint vertexID [[vertex_id]],\n"
	"    const device VertexIn *vertices [[buffer(0)]]) {\n"
	"    VertexOut out;\n"
	"    out.position = float4(vertices[vertexID].position, 0.0, 1.0);\n"
	"    out.texcoord = vertices[vertexID].texcoord;\n"
	"    return out;\n"
	"}\n"
	"fragment float4 rt_fragment_2d(VertexOut in [[stage_in]],\n"
	"    texture2d<float> tex [[texture(0)]], sampler samp [[sampler(0)]]) {\n"
	"    return tex.sample(samp, in.texcoord);\n"
	"}\n";

bool RT_EnsurePipeline2D( void )
{
	if ( rtPipeline2D != nil )
		return true;

	id<MTLDevice> device = RT_GetDevice();

	NSError *error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:rtShaderSource2D]
	                                                options:nil
	                                                  error:&error];
	if ( library == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to compile 2D shader: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	id<MTLFunction> vertexFn = [library newFunctionWithName:@"rt_vertex_2d"];
	id<MTLFunction> fragmentFn = [library newFunctionWithName:@"rt_fragment_2d"];

	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.vertexFunction = vertexFn;
	desc.fragmentFunction = fragmentFn;
	desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	desc.colorAttachments[0].blendingEnabled = YES;
	desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
	desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
	desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

	rtPipeline2D = [device newRenderPipelineStateWithDescriptor:desc error:&error];
	if ( rtPipeline2D == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to create 2D pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];
	samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
	samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
	samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
	samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
	rtSampler2D = [device newSamplerStateWithDescriptor:samplerDesc];

	return true;
}

} // namespace

// Session 22: RT_LoadImageFile and RT_FindShaderSkyParms below need
// external linkage (rt_world.mm's skybox loader calls both directly) -
// everything from here on is intentionally outside the anonymous
// namespace above for that reason, not just historical layout. Nothing
// below this point touches rtImages[]/numRtImages or any other state
// that still needs to stay internal (those functions - RT_RegisterImageCommon,
// RT_GetImageTexture, RT_GetImageBlendMode - already live past the
// anonymous namespace too, further down this file).

// Session 13: classifies a shader's `blendfunc` line into one of 3
// buckets (see rtBlendMode_t, rt_local.h) - mirrors ParseStage's own
// "simple blends first, then complex double blends" dispatch
// (tr_shader.c), minus a faithful mapping of every possible GL src/dst
// factor pair (Metal needs a distinct pipeline per blend config, so
// this renderer only maintains 3 - opaque, alpha, additive - rather
// than one per unique shader combination). `add`/`alphaadd` (an
// OPENMOHAA-specific preset) both classify as additive (their dst
// factor is always ONE - i.e. "accumulate onto the background," the
// defining trait of additive blending); `blend` and the complex
// double-token form classify as alpha (including "filter", a
// multiply-darken preset this renderer doesn't have a dedicated
// pipeline for - alpha blending is the closer approximation of the two
// non-opaque options).
rtBlendMode_t RT_ClassifyBlendFunc( char **p )
{
	char *token = COM_ParseExt( p, qfalse );
	if ( token[0] == '\0' )
		return RT_BLEND_OPAQUE;

	if ( !Q_stricmp( token, "add" ) || !Q_stricmp( token, "alphaadd" ) )
		return RT_BLEND_ADDITIVE;
	if ( !Q_stricmp( token, "filter" ) || !Q_stricmp( token, "blend" ) )
		return RT_BLEND_ALPHA;

	// Complex double-token form: <srcFactor> <dstFactor>. Only the dst
	// factor matters for this coarse classification - GLS_DSTBLEND_ONE
	// (dst factor "GL_ONE") is what every additive-looking blend has in
	// common, regardless of its src factor.
	char *dstToken = COM_ParseExt( p, qfalse );
	return ( !Q_stricmp( dstToken, "GL_ONE" ) ) ? RT_BLEND_ADDITIVE : RT_BLEND_ALPHA;
}

// Session 8: resolves a shader NAME (e.g. "ranger_top") to a real
// texture PATH (e.g. "textures/models/human/.../ranger_assaultvest.tga")
// by scanning every scripts/*.shader file for a matching top-level
// block, then scanning across ALL its stages (not just the first) for
// the first map/clampmap argument that isn't one of the three special
// non-file values ($whiteimage/$lightmap/$deluxemap) - some real world
// shaders put $lightmap in the first stage and the real diffuse texture
// in a later one (e.g. scripts/algiers.shader's lightplaster1: stage 1
// is "map $lightmap", stage 2 is the real texture). Mirrors the real
// renderer's FindShaderInShaderText + ParseStage's map/clampmap handling
// (tr_shader.c). Session 13 also classifies the block's `blendfunc`
// line, if any, via outBlendMode (defaults to RT_BLEND_OPAQUE if none
// found) - everything else a shader can specify (tcMod, rgbGen, sort,
// cull, deformVertexes, sky, fog...) is still silently skipped by the
// tokenizer's own "not a brace, not what we're looking for" fallthrough,
// which is correct parser behavior (not a "no silent no-ops" violation -
// unrecognized keywords are normal, not failures). Re-scans every
// .shader file per distinct miss rather than keeping one persistent
// concatenated buffer like the real renderer's startup-time
// ScanAndLoadShaderFiles - acceptable since RT_RegisterImageCommon below
// already caches by name, so this only ever runs once per distinct name
// actually requested, not per frame.
bool RT_FindShaderScriptTexture( const char *shaderName, char *outPath, size_t outPathSize, rtBlendMode_t *outBlendMode )
{
	if ( outBlendMode != NULL )
		*outBlendMode = RT_BLEND_OPAQUE;

	int numFiles = 0;
	char **fileList = ri.FS_ListFiles( "scripts", ".shader", &numFiles );
	if ( fileList == NULL )
		return false;

	bool found = false;

	for ( int f = 0; f < numFiles && !found; f++ )
	{
		char fullPath[MAX_QPATH];
		Com_sprintf( fullPath, sizeof( fullPath ), "scripts/%s", fileList[f] );

		byte *fileData = NULL;
		long fileLen = ri.FS_ReadFile( fullPath, (void **)&fileData );
		if ( fileLen <= 0 || fileData == NULL )
			continue;

		char *p = (char *)fileData;
		while ( true )
		{
			char *token = COM_ParseExt( &p, qtrue );
			if ( token[0] == '\0' )
				break;

			if ( Q_stricmp( token, shaderName ) != 0 )
			{
				SkipBracedSection( &p, 0 );
				continue;
			}

			// Matched the shader block by name - the next token must be
			// its opening brace; scan every stage inside for the first
			// real texture reference AND (session 13) any blendfunc -
			// keep scanning even after the texture's found, since
			// blendfunc can appear before or after "map" within the
			// same stage.
			char *openBrace = COM_ParseExt( &p, qtrue );
			if ( Q_stricmp( openBrace, "{" ) != 0 )
				break; // malformed shader block - give up on this file

			int depth = 1;
			while ( depth > 0 )
			{
				char *tok = COM_ParseExt( &p, qtrue );
				if ( tok[0] == '\0' )
					break;

				if ( !Q_stricmp( tok, "{" ) )
				{
					depth++;
					continue;
				}
				if ( !Q_stricmp( tok, "}" ) )
				{
					depth--;
					continue;
				}

				if ( !found && ( !Q_stricmp( tok, "map" ) || !Q_stricmpn( tok, "clampmap", 8 ) ) )
				{
					// Same-line only, matching ParseStage - a shader
					// script never breaks a map/clampmap argument across
					// lines.
					char *arg = COM_ParseExt( &p, qfalse );
					if ( arg[0] != '\0' && Q_stricmp( arg, "$whiteimage" ) != 0
						&& Q_stricmp( arg, "$lightmap" ) != 0 && Q_stricmp( arg, "$deluxemap" ) != 0 )
					{
						Q_strncpyz( outPath, arg, outPathSize );
						found = true;
					}
				}
				else if ( !Q_stricmp( tok, "blendfunc" ) && outBlendMode != NULL )
				{
					*outBlendMode = RT_ClassifyBlendFunc( &p );
				}
				else if ( !Q_stricmp( tok, "alphafunc" ) && outBlendMode != NULL )
				{
					// Session 20: coarse like RT_ClassifyBlendFunc - every
					// real alphaFunc variant (GE128/GT0/LT128) becomes the
					// same "discard below 50% alpha" cutout in the shader,
					// not a faithful per-variant threshold. GE128 (>= 50%
					// opaque) is by far the common case (foliage, fences,
					// chain-link) - see textures/misc_outside/treeline_center.
					COM_ParseExt( &p, qfalse ); // consume GE128/GT0/LT128 - not used
					*outBlendMode = RT_BLEND_ALPHATEST;
				}
			}

			break; // done with this shader block
		}

		ri.FS_FreeFile( fileData );
	}

	ri.FS_FreeFileList( fileList );
	return found;
}

// Session 22: a sky shader (e.g. textures/sky/mohday2) has no map/
// clampmap stage at all - just `skyParms <basePath> <cloudHeight>
// <box>` at the shader-block's top level - so RT_FindShaderScriptTexture
// above correctly never finds a texture for one (not a bug, that
// function's whole job is finding a map/clampmap stage). Kept as its
// own separate scan, rather than folded into that function with more
// out-parameters, so world-shader sky detection (rt_world.mm, the only
// caller) can't accidentally perturb the already-working texture/
// blendfunc/alphafunc resolution every other caller (2D UI, entities)
// depends on. Only the base path is extracted - cloudHeight and the
// box/terrain-fog parameter aren't used by this renderer's skybox.
bool RT_FindShaderSkyParms( const char *shaderName, char *outBasePath, size_t outBasePathSize )
{
	int numFiles = 0;
	char **fileList = ri.FS_ListFiles( "scripts", ".shader", &numFiles );
	if ( fileList == NULL )
		return false;

	bool found = false;

	for ( int f = 0; f < numFiles && !found; f++ )
	{
		char fullPath[MAX_QPATH];
		Com_sprintf( fullPath, sizeof( fullPath ), "scripts/%s", fileList[f] );

		byte *fileData = NULL;
		long fileLen = ri.FS_ReadFile( fullPath, (void **)&fileData );
		if ( fileLen <= 0 || fileData == NULL )
			continue;

		char *p = (char *)fileData;
		while ( true )
		{
			char *token = COM_ParseExt( &p, qtrue );
			if ( token[0] == '\0' )
				break;

			if ( Q_stricmp( token, shaderName ) != 0 )
			{
				SkipBracedSection( &p, 0 );
				continue;
			}

			char *openBrace = COM_ParseExt( &p, qtrue );
			if ( Q_stricmp( openBrace, "{" ) != 0 )
				break;

			int depth = 1;
			while ( depth > 0 )
			{
				char *tok = COM_ParseExt( &p, qtrue );
				if ( tok[0] == '\0' )
					break;

				if ( !Q_stricmp( tok, "{" ) )
				{
					depth++;
					continue;
				}
				if ( !Q_stricmp( tok, "}" ) )
				{
					depth--;
					continue;
				}

				if ( !Q_stricmp( tok, "skyparms" ) )
				{
					char *arg = COM_ParseExt( &p, qfalse );
					if ( arg[0] != '\0' && Q_stricmp( arg, "-" ) != 0 )
					{
						Q_strncpyz( outBasePath, arg, outBasePathSize );
						found = true;
					}
				}
			}

			break; // done with this shader block
		}

		ri.FS_FreeFile( fileData );
	}

	ri.FS_FreeFileList( fileList );
	return found;
}

// RegisterShader treats its name as a direct image path, trying common
// extensions in turn if the name doesn't already have one - the same
// job R_LoadImage does in the existing renderers, minus DDS/S3TC (no
// content this session has needed it, and it's a bigger lift to also
// support natively - revisit if/when it comes up).
byte *RT_LoadImageFile( const char *name, int *width, int *height )
{
	char localName[MAX_QPATH];
	const char *ext;
	byte *pic = NULL;

	Q_strncpyz( localName, name, sizeof( localName ) );
	ext = COM_GetExtension( localName );

	struct loaderEntry_t {
		const char *ext;
		void ( *loader )( const char *, byte **, int *, int * );
	};
	static const loaderEntry_t loaders[] = {
		{ "tga", R_LoadTGA },
		{ "bmp", R_LoadBMP },
		{ "pcx", R_LoadPCX },
		{ "jpg", R_LoadJPG },
		{ "png", R_LoadPNG },
	};

	if ( ext && *ext )
	{
		for ( const loaderEntry_t &entry : loaders )
		{
			if ( !Q_stricmp( ext, entry.ext ) )
			{
				entry.loader( localName, &pic, width, height );
				break;
			}
		}

		if ( pic != NULL )
			return pic;

		// The named extension didn't exist on disk (or wasn't one of
		// ours) - fall through to try every other extension against the
		// same base name, matching the real engine's R_FindImageFile.
		// Common in this era's assets: a .shader script says "map
		// foo.tga" but only foo.jpg ever shipped.
	}

	char base[MAX_QPATH];
	COM_StripExtension( name, base, sizeof( base ) );

	for ( const loaderEntry_t &entry : loaders )
	{
		char full[MAX_QPATH];
		Com_sprintf( full, sizeof( full ), "%s.%s", base, entry.ext );
		entry.loader( full, &pic, width, height );
		if ( pic != NULL )
			return pic;
	}

	return NULL;
}

id<MTLTexture> RT_CreateTexture( const byte *rgba, int width, int height )
{
	MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
	                                                                                 width:width
	                                                                                height:height
	                                                                             mipmapped:NO];
	desc.usage = MTLTextureUsageShaderRead;
	id<MTLTexture> texture = [RT_GetDevice() newTextureWithDescriptor:desc];

	MTLRegion region = MTLRegionMake2D( 0, 0, width, height );
	[texture replaceRegion:region mipmapLevel:0 withBytes:rgba bytesPerRow:width * 4];

	return texture;
}

// rt_scene.mm's session-7 model-texturing
// bake step calls this directly (with a TIKI surface's shader name
// instead of a UI DrawStretchPic image path) to reuse the same
// direct-image-file loader rather than duplicating it. Still freely
// calls the namespace-internal helpers above (rtImages/numRtImages/
// RT_LoadImageFile/RT_EnsurePipeline2D/RT_CreateTexture) - anonymous
// namespace members stay visible throughout this one file, just not to
// other translation units.
qhandle_t RT_RegisterImageCommon( const char *name )
{
	if ( !name || !name[0] )
		return 0;

	for ( int i = 1; i <= numRtImages; i++ )
	{
		if ( !Q_stricmp( rtImages[i].name, name ) )
			return i;
	}

	// Real .shader script lookup first, matching R_FindShaderEx's own
	// order (tr_shader.c) - only falls back to treating the name as a
	// direct image file (the ONLY thing this function did before session
	// 8) if no shader script defines it, same as the real renderer does
	// for a name with no .shader entry at all.
	char strippedName[MAX_QPATH];
	COM_StripExtension( name, strippedName, sizeof( strippedName ) );

	char resolvedPath[MAX_QPATH];
	int width = 0, height = 0;
	byte *pic = NULL;
	rtBlendMode_t blendMode = RT_BLEND_OPAQUE;
	if ( RT_FindShaderScriptTexture( strippedName, resolvedPath, sizeof( resolvedPath ), &blendMode ) )
		pic = RT_LoadImageFile( resolvedPath, &width, &height );

	if ( pic == NULL )
		pic = RT_LoadImageFile( name, &width, &height );

	if ( pic == NULL )
	{
		// Honest limitation, not a bug: only a shader script's first
		// resolvable map/clampmap texture, or a direct image file, ever
		// resolves - a shader that only uses generated/procedural stages
		// (animMaps, videoMaps, $whiteimage-only stages, etc.) or a name
		// that's neither a shader nor an image still won't. Warn once so
		// a missing/mismatched name is visible, then hand back the
		// invalid handle like a genuinely-missing image would.
		ri.Printf( PRINT_WARNING, "renderer_metalrt: RegisterShader: couldn't resolve a texture for \"%s\" "
			"(no shader script or direct image file matched)\n", name );
		return 0;
	}

	if ( numRtImages + 1 >= MAX_RT_IMAGES )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: RegisterShader: MAX_RT_IMAGES (%d) hit, dropping \"%s\"\n",
			MAX_RT_IMAGES, name );
		ri.Free( pic );
		return 0;
	}

	if ( !RT_EnsurePipeline2D() )
	{
		ri.Free( pic );
		return 0;
	}

	numRtImages++;
	rtImage_t *img = &rtImages[numRtImages];
	Q_strncpyz( img->name, name, sizeof( img->name ) );
	img->width = width;
	img->height = height;
	img->blendMode = blendMode;
	img->texture = RT_CreateTexture( pic, width, height );

	ri.Free( pic );

	ri.Printf( PRINT_DEVELOPER, "renderer_metalrt: registered shader \"%s\" -> handle %d (%dx%d)\n",
		name, numRtImages, width, height );

	return numRtImages;
}

// Same reasoning as RT_RegisterImageCommon above - rt_scene.mm needs the
// actual MTLTexture for a resolved handle to bind it for a 3D draw call.
id<MTLTexture> RT_GetImageTexture( qhandle_t handle )
{
	if ( handle <= 0 || handle > numRtImages )
		return nil;
	return rtImages[handle].texture;
}

// Session 13: same reasoning - rt_scene.mm needs a resolved surface
// texture's blend classification to pick the right 3D pipeline variant.
rtBlendMode_t RT_GetImageBlendMode( qhandle_t handle )
{
	if ( handle <= 0 || handle > numRtImages )
		return RT_BLEND_OPAQUE;
	return rtImages[handle].blendMode;
}

// Session 19: these three and CountTextureMemory below were previously
// loud stubs always returning 0/"" - real values were sitting right
// here in rtImage_t the whole time (width/height/name are all recorded
// at registration, see RT_RegisterImageCommon above), just never wired
// up. Cgame UI layout code calls GetShaderWidth/Height to size icons
// correctly, so the old 0-always stub likely caused invisible-or-
// wrong-size HUD elements - not verified live (screen locked this
// session), but these are pure accessors with zero interaction with
// the render path, so there's nothing here that could newly break
// already-working rendering even if unverified visually.
int RT_GetShaderWidth( qhandle_t hShader )
{
	if ( hShader <= 0 || hShader > numRtImages )
		return 0;
	return rtImages[hShader].width;
}

int RT_GetShaderHeight( qhandle_t hShader )
{
	if ( hShader <= 0 || hShader > numRtImages )
		return 0;
	return rtImages[hShader].height;
}

const char *RT_GetShaderName( qhandle_t hShader )
{
	if ( hShader <= 0 || hShader > numRtImages )
		return "";
	return rtImages[hShader].name;
}

// Matches the real renderers' definition closely enough for its only
// real use (console/diagnostic reporting, not a hard budget check):
// sum of each registered texture's raw RGBA byte count, ignoring
// mipmaps (this renderer doesn't generate any, see RT_CreateTexture).
int RT_CountTextureMemory( void )
{
	int total = 0;
	for ( int i = 1; i <= numRtImages; i++ )
		total += rtImages[i].width * rtImages[i].height * 4;
	return total;
}

static qhandle_t RT_RegisterShader( const char *name )
{
	return RT_RegisterImageCommon( name );
}

static qhandle_t RT_RegisterShaderNoMip( const char *name )
{
	return RT_RegisterImageCommon( name );
}

static void RT_Set2DWindow( int x, int y, int w, int h, float left, float right, float bottom, float top, float n, float f )
{
	rt2DWindow.vx = (float)x;
	rt2DWindow.vy = (float)y;
	rt2DWindow.vw = (float)w;
	rt2DWindow.vh = (float)h;
	rt2DWindow.left = left;
	rt2DWindow.right = right;
	rt2DWindow.bottom = bottom;
	rt2DWindow.top = top;
	rt2DWindowInitialized = true;
	// n/f (near/far) are meaningless for this CPU-side 2D remap - depth
	// testing is disabled for 2D draws (there's no depth attachment use
	// in RT_DrawStretchPic), so they're accepted for ABI compatibility
	// and otherwise unused, matching how little they do even in the real
	// renderer's ortho matrix (z range for a surface that never varies
	// in Z isn't visually meaningful).
}

static void RT_Scissor( int x, int y, int width, int height )
{
	id<MTLRenderCommandEncoder> encoder = RT_GetCurrentEncoder();
	if ( encoder == nil )
		return;

	// y follows the same OpenGL bottom-up glScissor convention as
	// Set2DWindow's vy (UIWidget::set2D computes both from the same
	// "vidHeight - (rect's local bottom edge)" formula) - convert to
	// Metal's top-down scissor-rect Y the same way RT_MapLocalToScreen
	// does, rather than using y directly.
	int metalTopY = rtGlConfig.vidHeight - ( y + height );

	// Metal asserts if a scissor rect extends past the render target -
	// clamp rather than let a widget's clip rect (computed against the
	// engine's own vidWidth/vidHeight) crash on a rounding edge case.
	int clampedX = ( x < 0 ) ? 0 : ( x > rtGlConfig.vidWidth ? rtGlConfig.vidWidth : x );
	int clampedY = ( metalTopY < 0 ) ? 0 : ( metalTopY > rtGlConfig.vidHeight ? rtGlConfig.vidHeight : metalTopY );
	int maxW = rtGlConfig.vidWidth - clampedX;
	int maxH = rtGlConfig.vidHeight - clampedY;
	int clampedW = ( width < 0 ) ? 0 : ( width > maxW ? maxW : width );
	int clampedH = ( height < 0 ) ? 0 : ( height > maxH ? maxH : height );

	MTLScissorRect rect;
	rect.x = (NSUInteger)clampedX;
	rect.y = (NSUInteger)clampedY;
	rect.width = (NSUInteger)clampedW;
	rect.height = (NSUInteger)clampedH;
	[encoder setScissorRect:rect];
}

// Not static: rt_font.mm (session 12) calls this directly, once per
// glyph, to draw each character's quad - text rendering is "the same
// textured-quad draw DrawStretchPic already does, just looped," so it
// reuses this exact function rather than duplicating the local-to-screen
// mapping/pipeline/encoding logic a second time.
void RT_DrawStretchPic( float x, float y, float w, float h,
	float s1, float t1, float s2, float t2, qhandle_t hShader )
{
	id<MTLRenderCommandEncoder> encoder = RT_GetCurrentEncoder();
	if ( encoder == nil || rtPipeline2D == nil )
		return;

	if ( hShader <= 0 || hShader > numRtImages )
	{
		RT_STUB_ONCE(); // invalid/unregistered handle - nothing to draw yet
		return;
	}

	rtImage_t *img = &rtImages[hShader];

	// x/y/w/h/s/t come in the CURRENT Set2DWindow's local coordinate
	// space, not raw screen pixels - uiwidget.cpp's widgets each call
	// Set2DWindow with their own viewport+origin, then draw themselves
	// at local (0,0,width,height) relying entirely on this mapping to
	// land at their real position (see rt2DWindow's comment above).
	RT_EnsureDefault2DWindow();

	float screenX0, screenY0, screenX1, screenY1;
	RT_MapLocalToScreen( x, y, &screenX0, &screenY0 );
	RT_MapLocalToScreen( x + w, y + h, &screenX1, &screenY1 );

	float ndcX0 = ( screenX0 / rtGlConfig.vidWidth ) * 2.0f - 1.0f;
	float ndcX1 = ( screenX1 / rtGlConfig.vidWidth ) * 2.0f - 1.0f;
	float ndcY0 = 1.0f - ( screenY0 / rtGlConfig.vidHeight ) * 2.0f;
	float ndcY1 = 1.0f - ( screenY1 / rtGlConfig.vidHeight ) * 2.0f;

	RTVertex2D verts[4] = {
		{ { ndcX0, ndcY0 }, { s1, t1 } },
		{ { ndcX1, ndcY0 }, { s2, t1 } },
		{ { ndcX0, ndcY1 }, { s1, t2 } },
		{ { ndcX1, ndcY1 }, { s2, t2 } },
	};

	id<MTLBuffer> vbuf = [RT_GetDevice() newBufferWithBytes:verts length:sizeof( verts ) options:MTLResourceStorageModeShared];

	[encoder setRenderPipelineState:rtPipeline2D];
	[encoder setVertexBuffer:vbuf offset:0 atIndex:0];
	[encoder setFragmentTexture:img->texture atIndex:0];
	[encoder setFragmentSamplerState:rtSampler2D atIndex:0];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

void RT_InitImageFunctions( refexport_t *re )
{
	re->RegisterShader = RT_RegisterShader;
	re->RegisterShaderNoMip = RT_RegisterShaderNoMip;
	re->DrawStretchPic = RT_DrawStretchPic;
	re->Set2DWindow = RT_Set2DWindow;
	re->Scissor = RT_Scissor;
	re->GetShaderWidth = RT_GetShaderWidth;
	re->GetShaderHeight = RT_GetShaderHeight;
	re->GetShaderName = RT_GetShaderName;
	re->CountTextureMemory = RT_CountTextureMemory;
}

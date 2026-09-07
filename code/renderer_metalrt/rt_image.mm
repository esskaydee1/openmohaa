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
// safe to use unchanged from a native Metal renderer. Only the
// dependency-free formats this session (TGA/BMP/PCX are plain C, no
// external library); JPG needs libjpeg and PNG needs puff.c's inflate -
// both real, but a separate CMake-wiring session, not bundled into
// "get RegisterShader/DrawStretchPic working" for the first time.
extern "C" {
void R_LoadTGA( const char *name, byte **pic, int *width, int *height );
void R_LoadBMP( const char *name, byte **pic, int *width, int *height );
void R_LoadPCX( const char *name, byte **pic, int *width, int *height );
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
};

#define MAX_RT_IMAGES 1024
rtImage_t rtImages[MAX_RT_IMAGES]; // index 0 unused - handle 0 means "invalid"
int numRtImages = 0;

id<MTLRenderPipelineState> rtPipeline2D = nil;
id<MTLSamplerState> rtSampler2D = nil;

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
	};

	if ( ext && *ext )
	{
		for ( const loaderEntry_t &entry : loaders )
		{
			if ( !Q_stricmp( ext, entry.ext ) )
			{
				entry.loader( localName, &pic, width, height );
				return pic;
			}
		}
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

qhandle_t RT_RegisterImageCommon( const char *name )
{
	if ( !name || !name[0] )
		return 0;

	for ( int i = 1; i <= numRtImages; i++ )
	{
		if ( !Q_stricmp( rtImages[i].name, name ) )
			return i;
	}

	int width = 0, height = 0;
	byte *pic = RT_LoadImageFile( name, &width, &height );
	if ( pic == NULL )
	{
		// Honest limitation, not a bug: RegisterShader only understands
		// direct image files this session, not .shader scripts. Warn
		// once so a missing/mismatched name is visible, then hand back
		// the invalid handle like a genuinely-missing image would.
		ri.Printf( PRINT_WARNING, "renderer_metalrt: RegisterShader: couldn't load image for \"%s\" "
			"(no .shader script support yet - see Phase 2)\n", name );
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
	img->texture = RT_CreateTexture( pic, width, height );

	ri.Free( pic );

	ri.Printf( PRINT_DEVELOPER, "renderer_metalrt: registered shader \"%s\" -> handle %d (%dx%d)\n",
		name, numRtImages, width, height );

	return numRtImages;
}

} // namespace

static qhandle_t RT_RegisterShader( const char *name )
{
	return RT_RegisterImageCommon( name );
}

static qhandle_t RT_RegisterShaderNoMip( const char *name )
{
	return RT_RegisterImageCommon( name );
}

static void RT_DrawStretchPic( float x, float y, float w, float h,
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

	// x/y/w/h/s/t come in screen-pixel space with (0,0) at the top-left
	// (the engine's usual 2D convention); project straight to Metal NDC
	// on the CPU rather than carrying a projection matrix/uniform for
	// this first pass.
	float ndcX0 = ( x / rtGlConfig.vidWidth ) * 2.0f - 1.0f;
	float ndcX1 = ( ( x + w ) / rtGlConfig.vidWidth ) * 2.0f - 1.0f;
	float ndcY0 = 1.0f - ( y / rtGlConfig.vidHeight ) * 2.0f;
	float ndcY1 = 1.0f - ( ( y + h ) / rtGlConfig.vidHeight ) * 2.0f;

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
}

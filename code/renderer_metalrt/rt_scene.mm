/*
===========================================================================
renderer_metalrt - Phase 1 session 3: minimal RegisterModel + a real 3D
scene path (ClearScene/AddRefEntityToScene/RenderScene).

Deliberately a placeholder, not real model rendering: RegisterModel only
checks that a named .tik file exists (real TIKI parsing/skinning is its
own, much bigger session - see docs/ARCHITECTURE.md's port-scope notes
on TIKI). Every RT_MODEL entity submitted with a valid handle draws as a
flat magenta box at its correct world position/orientation, viewed
through a real camera built from the refdef_t the game actually submits
(fov_x/fov_y, vieworg, viewaxis) - this proves the whole real data path
(registration -> submission -> per-frame scene -> camera -> depth-tested
3D draw) end to end before any real geometry exists to put through it.
===========================================================================
*/
#include "rt_local.h"

#include <math.h>
#include <simd/simd.h>
#include <vector>

// rt_image.mm (not anonymous-namespace-scoped there, see its comments) -
// reused here to resolve a TIKI surface's shader name to a texture the
// same way DrawStretchPic resolves a UI image name, rather than
// duplicating the direct-image-file loader.
qhandle_t RT_RegisterImageCommon( const char *name );
id<MTLTexture> RT_GetImageTexture( qhandle_t handle );
rtBlendMode_t RT_GetImageBlendMode( qhandle_t handle );

namespace {

#define MAX_RT_MODEL_SURFACES 32

// One real mesh surface's worth of a model's shared index buffer, plus
// whichever texture its TIKI-level `surface <name> shader <name>` line
// resolved to (session 7) - nil means no resolvable texture (most
// .shader-script names still don't resolve, see RT_RegisterImageCommon's
// "no .shader script support yet" warning), in which case this surface
// draws through the flat-magenta fallback pipeline instead, same as
// every model did before this session. blendMode (session 13) is only
// meaningful when texture != nil - it picks which of the 3 textured
// pipeline variants (opaque/alpha/additive) draws this surface.
struct rtModelSurface_t {
	uint32_t indexOffset; // element (not byte) offset into the model's indexBuffer
	uint32_t indexCount;
	id<MTLTexture> texture;
	rtBlendMode_t blendMode;
};

struct rtModel_t {
	char name[MAX_QPATH];
	// Real baked TIKI geometry (session 6) - nil/0 means "bake failed or
	// this model has no mesh data", in which case RT_RenderScene falls
	// back to the flat-magenta placeholder box, same as every model drew
	// before this session.
	id<MTLBuffer> vertexBuffer;
	// Parallel to vertexBuffer (same per-vertex indexing) - always baked
	// alongside positions since the source data's already right there
	// (skeletorVertex_t::texCoords), even for surfaces that end up with
	// no resolvable texture; cheap to keep unconditionally rather than
	// track whether any surface of this model ended up needing it.
	id<MTLBuffer> texcoordBuffer;
	// Session 10: per-vertex normal, transformed into model space by the
	// vertex's first bone weight only (matching the real renderer's own
	// SkelVertGetNormal, tr_model.cpp - normals use a single dominant
	// bone even in the fully-correct animated path, unlike positions
	// which sum every weight). Rotated into world space per-draw by the
	// entity's own rotation (RT_RenderScene), same as position's model
	// matrix.
	id<MTLBuffer> normalBuffer;
	id<MTLBuffer> indexBuffer;
	int indexCount;
	int numSurfaces;
	rtModelSurface_t surfaces[MAX_RT_MODEL_SURFACES];
};

#define MAX_RT_MODELS 1024
rtModel_t rtModels[MAX_RT_MODELS]; // index 0 unused - handle 0 is invalid
int numRtModels = 0;

struct rtSceneEntity_t {
	float origin[3];
	float axis[3][3];
	qhandle_t hModel;
};

#define MAX_RT_SCENE_ENTITIES 1024
rtSceneEntity_t rtSceneEntities[MAX_RT_SCENE_ENTITIES];
int numRtSceneEntities = 0;

id<MTLRenderPipelineState> rtPipeline3D = nil;
id<MTLDepthStencilState> rtDepthState3D = nil;
id<MTLBuffer> rtBoxVertexBuffer = nil;
id<MTLBuffer> rtBoxNormalBuffer = nil;
int rtBoxVertexCount = 0;

// Shared by both entity placeholders (magenta) and world geometry (gray,
// see rt_world.mm) - same vertex function, one fragment color uniform
// so both can reuse this one pipeline/depth state rather than each
// needing their own.
//
// Session 10: real per-vertex lighting - a single fixed directional
// "sun" (RT_GetLightDir below), not yet anything derived from the map's
// actual light entities or BSP lightgrid (that's real, separate work -
// this session's honest scope is "shading exists and responds to
// surface orientation," not "matches the original game's lighting").
// normalMatrix rotates a model-space normal into world space - for
// world geometry (identity model matrix) that's just the identity;
// for an entity it's the same rotation as its model matrix, extracted
// as a 3x3 (valid directly, no inverse-transpose needed, since
// RT_BuildModelMatrix's axes are always orthonormal - no non-uniform
// scale to correct for).
const char *rtShaderSource3D =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct VertexOut { float4 position [[position]]; float3 worldNormal; };\n"
	"vertex VertexOut rt_vertex_3d(uint vertexID [[vertex_id]],\n"
	"    const device float3 *positions [[buffer(0)]],\n"
	"    constant float4x4 &mvp [[buffer(1)]],\n"
	"    const device float3 *normals [[buffer(2)]],\n"
	"    constant float3x3 &normalMatrix [[buffer(3)]]) {\n"
	"    VertexOut out;\n"
	"    out.position = mvp * float4(positions[vertexID], 1.0);\n"
	"    out.worldNormal = normalMatrix * normals[vertexID];\n"
	"    return out;\n"
	"}\n"
	"fragment float4 rt_fragment_3d(VertexOut in [[stage_in]],\n"
	"    constant float4 &color [[buffer(0)]],\n"
	"    constant float3 &lightDir [[buffer(1)]]) {\n"
	"    float3 n = normalize(in.worldNormal);\n"
	"    float ndotl = max(dot(n, lightDir), 0.0);\n"
	"    float lighting = mix(0.35, 1.0, ndotl);\n"
	"    return float4(color.rgb * lighting, color.a);\n"
	"}\n";

id<MTLRenderPipelineState> rtPipelineTextured3D = nil;
// Session 13: two more textured pipeline variants for non-opaque
// surfaces (see rtBlendMode_t, rt_local.h) - same shader, different
// color-attachment blend config each.
id<MTLRenderPipelineState> rtPipelineTexturedAlpha3D = nil;
id<MTLRenderPipelineState> rtPipelineTexturedAdditive3D = nil;
// Session 20: opaque blend config like rtPipelineTextured3D (no
// blending, depth write on) - the "cut out or fully there" look comes
// from rt_fragment_3d_tex_alphatest's discard, not from blend state.
id<MTLRenderPipelineState> rtPipelineTexturedAlphaTest3D = nil;
id<MTLDepthStencilState> rtDepthStateBlended3D = nil;
id<MTLSamplerState> rtSamplerTextured3D = nil;

// Session 7: a real per-surface texture, reusing rt_vertex_3d's exact
// position/mvp handling (buffer 0/1) and only adding a second, separate
// per-vertex buffer (2) for texcoords - kept as a parallel array rather
// than interleaved with position so the untextured flat path above can
// keep reading a model's positions buffer completely unchanged.
// Session 10: same normal/normalMatrix lighting as rt_vertex_3d/
// rt_fragment_3d above, applied to the sampled texture color instead of
// a flat uniform color.
const char *rtShaderSourceTextured3D =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct VertexOutTex { float4 position [[position]]; float2 texcoord; float3 worldNormal; };\n"
	"vertex VertexOutTex rt_vertex_3d_tex(uint vertexID [[vertex_id]],\n"
	"    const device float3 *positions [[buffer(0)]],\n"
	"    constant float4x4 &mvp [[buffer(1)]],\n"
	"    const device float2 *texcoords [[buffer(2)]],\n"
	"    const device float3 *normals [[buffer(3)]],\n"
	"    constant float3x3 &normalMatrix [[buffer(4)]]) {\n"
	"    VertexOutTex out;\n"
	"    out.position = mvp * float4(positions[vertexID], 1.0);\n"
	"    out.texcoord = texcoords[vertexID];\n"
	"    out.worldNormal = normalMatrix * normals[vertexID];\n"
	"    return out;\n"
	"}\n"
	"fragment float4 rt_fragment_3d_tex(VertexOutTex in [[stage_in]],\n"
	"    texture2d<float> tex [[texture(0)]], sampler samp [[sampler(0)]],\n"
	"    constant float3 &lightDir [[buffer(0)]]) {\n"
	"    float4 texColor = tex.sample(samp, in.texcoord);\n"
	"    float3 n = normalize(in.worldNormal);\n"
	"    float ndotl = max(dot(n, lightDir), 0.0);\n"
	"    float lighting = mix(0.35, 1.0, ndotl);\n"
	"    return float4(texColor.rgb * lighting, texColor.a);\n"
	"}\n"
	// Session 20: same shading as rt_fragment_3d_tex, but discards
	// fully instead of blending wherever the texture's alpha is below
	// 50% - a shader's `alphaFunc` (cutout foliage/fences/chain-link,
	// as opposed to `blendFunc`'s smooth blending) needs this: without
	// it, the texture's fully-transparent background pixels (usually
	// black) render as solid opaque black instead of vanishing.
	"fragment float4 rt_fragment_3d_tex_alphatest(VertexOutTex in [[stage_in]],\n"
	"    texture2d<float> tex [[texture(0)]], sampler samp [[sampler(0)]],\n"
	"    constant float3 &lightDir [[buffer(0)]]) {\n"
	"    float4 texColor = tex.sample(samp, in.texcoord);\n"
	"    if (texColor.a < 0.5) discard_fragment();\n"
	"    float3 n = normalize(in.worldNormal);\n"
	"    float ndotl = max(dot(n, lightDir), 0.0);\n"
	"    float lighting = mix(0.35, 1.0, ndotl);\n"
	"    return float4(texColor.rgb * lighting, 1.0);\n"
	"}\n";

} // namespace

// Session 14: non-static (moved out of the anonymous namespace above,
// where it originally lived) so rt_world.mm can also ensure/use the
// textured pipelines for real world-surface texturing, not just
// rt_scene.mm's entity surfaces.
bool RT_EnsurePipelineTextured3D( void )
{
	if ( rtPipelineTextured3D != nil )
		return true;

	id<MTLDevice> device = RT_GetDevice();

	NSError *error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:rtShaderSourceTextured3D]
	                                                options:nil
	                                                  error:&error];
	if ( library == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to compile textured 3D shader: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	id<MTLFunction> vertexFn = [library newFunctionWithName:@"rt_vertex_3d_tex"];
	id<MTLFunction> fragmentFn = [library newFunctionWithName:@"rt_fragment_3d_tex"];
	id<MTLFunction> fragmentFnAlphaTest = [library newFunctionWithName:@"rt_fragment_3d_tex_alphatest"];

	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.vertexFunction = vertexFn;
	desc.fragmentFunction = fragmentFn;
	desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

	rtPipelineTextured3D = [device newRenderPipelineStateWithDescriptor:desc error:&error];
	if ( rtPipelineTextured3D == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to create textured 3D pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	// Session 13: two more pipeline STATES sharing the exact same
	// compiled vertex/fragment functions above, differing only in their
	// color-attachment blend config - one Metal shader, three PSOs,
	// rather than three separate shader compiles.
	MTLRenderPipelineDescriptor *alphaDesc = [[MTLRenderPipelineDescriptor alloc] init];
	alphaDesc.vertexFunction = vertexFn;
	alphaDesc.fragmentFunction = fragmentFn;
	alphaDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	alphaDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	alphaDesc.colorAttachments[0].blendingEnabled = YES;
	alphaDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
	alphaDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
	alphaDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	alphaDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	alphaDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	alphaDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

	rtPipelineTexturedAlpha3D = [device newRenderPipelineStateWithDescriptor:alphaDesc error:&error];
	if ( rtPipelineTexturedAlpha3D == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to create alpha-blended textured 3D pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	MTLRenderPipelineDescriptor *additiveDesc = [[MTLRenderPipelineDescriptor alloc] init];
	additiveDesc.vertexFunction = vertexFn;
	additiveDesc.fragmentFunction = fragmentFn;
	additiveDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	additiveDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	additiveDesc.colorAttachments[0].blendingEnabled = YES;
	additiveDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
	additiveDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
	additiveDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
	additiveDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	additiveDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
	additiveDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;

	rtPipelineTexturedAdditive3D = [device newRenderPipelineStateWithDescriptor:additiveDesc error:&error];
	if ( rtPipelineTexturedAdditive3D == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to create additive textured 3D pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	// Session 20: opaque blend config, same as rtPipelineTextured3D's
	// descriptor above, just the alpha-test fragment function instead.
	MTLRenderPipelineDescriptor *alphaTestDesc = [[MTLRenderPipelineDescriptor alloc] init];
	alphaTestDesc.vertexFunction = vertexFn;
	alphaTestDesc.fragmentFunction = fragmentFnAlphaTest;
	alphaTestDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	alphaTestDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

	rtPipelineTexturedAlphaTest3D = [device newRenderPipelineStateWithDescriptor:alphaTestDesc error:&error];
	if ( rtPipelineTexturedAlphaTest3D == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to create alpha-test textured 3D pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	// Blended/transparent surfaces test depth (so solid geometry in
	// front still occludes them) but don't write it - otherwise a
	// transparent surface would incorrectly block whatever draws behind
	// it later in the same frame, including other transparent surfaces.
	MTLDepthStencilDescriptor *blendedDepthDesc = [[MTLDepthStencilDescriptor alloc] init];
	blendedDepthDesc.depthCompareFunction = MTLCompareFunctionLess;
	blendedDepthDesc.depthWriteEnabled = NO;
	rtDepthStateBlended3D = [device newDepthStencilStateWithDescriptor:blendedDepthDesc];

	MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];
	samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
	samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
	samplerDesc.sAddressMode = MTLSamplerAddressModeRepeat;
	samplerDesc.tAddressMode = MTLSamplerAddressModeRepeat;
	rtSamplerTextured3D = [device newSamplerStateWithDescriptor:samplerDesc];

	return true;
}

// Session 14: a shared, non-indexed textured draw helper - both
// rt_scene.mm's own per-entity-surface draws could use this, but they
// already had their own (indexed) version before this session existed;
// left as-is rather than unifying an indexed and non-indexed path into
// one function. World geometry (rt_world.mm) has no index buffer at
// all (session 4's design - a flat, non-indexed triangle list), so its
// per-shader-group draws call this instead.
void RT_DrawTexturedGeometry( id<MTLBuffer> vertexBuffer, id<MTLBuffer> texcoordBuffer, id<MTLBuffer> normalBuffer,
	int vertexStart, int vertexCount, simd_float4x4 mvp, simd_float3x3 normalMatrix,
	id<MTLTexture> texture, rtBlendMode_t blendMode, simd_float3 lightDir )
{
	id<MTLRenderCommandEncoder> encoder = RT_GetCurrentEncoder();
	if ( encoder == nil )
		return;

	id<MTLRenderPipelineState> pipeline = rtPipelineTextured3D;
	id<MTLDepthStencilState> depthState = rtDepthState3D;
	if ( blendMode == RT_BLEND_ALPHA )
	{
		pipeline = rtPipelineTexturedAlpha3D;
		depthState = rtDepthStateBlended3D;
	}
	else if ( blendMode == RT_BLEND_ADDITIVE )
	{
		pipeline = rtPipelineTexturedAdditive3D;
		depthState = rtDepthStateBlended3D;
	}
	else if ( blendMode == RT_BLEND_ALPHATEST )
	{
		// Opaque depth state (write enabled), same as the default case -
		// alpha-tested surfaces are per-pixel either fully there or fully
		// gone, not partially transparent, so they occlude normally.
		pipeline = rtPipelineTexturedAlphaTest3D;
	}

	[encoder setRenderPipelineState:pipeline];
	[encoder setDepthStencilState:depthState];
	[encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
	[encoder setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];
	[encoder setVertexBuffer:texcoordBuffer offset:0 atIndex:2];
	[encoder setVertexBuffer:normalBuffer offset:0 atIndex:3];
	[encoder setVertexBytes:&normalMatrix length:sizeof( normalMatrix ) atIndex:4];
	[encoder setFragmentTexture:texture atIndex:0];
	[encoder setFragmentSamplerState:rtSamplerTextured3D atIndex:0];
	[encoder setFragmentBytes:&lightDir length:sizeof( lightDir ) atIndex:0];

	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:vertexStart vertexCount:vertexCount];
}

// Non-static so rt_world.mm can reuse the same pipeline/depth state
// (world geometry and entity placeholders share both) rather than
// standing up a second, near-identical copy.
bool RT_EnsurePipeline3D( void )
{
	if ( rtPipeline3D != nil )
		return true;

	id<MTLDevice> device = RT_GetDevice();

	NSError *error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:rtShaderSource3D]
	                                                options:nil
	                                                  error:&error];
	if ( library == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to compile 3D shader: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.vertexFunction = [library newFunctionWithName:@"rt_vertex_3d"];
	desc.fragmentFunction = [library newFunctionWithName:@"rt_fragment_3d"];
	desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

	rtPipeline3D = [device newRenderPipelineStateWithDescriptor:desc error:&error];
	if ( rtPipeline3D == nil )
	{
		ri.Printf( PRINT_ERROR, "renderer_metalrt: failed to create 3D pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
	depthDesc.depthCompareFunction = MTLCompareFunctionLess;
	depthDesc.depthWriteEnabled = YES;
	rtDepthState3D = [device newDepthStencilStateWithDescriptor:depthDesc];

	// A simple axis-aligned box, roughly player-sized (Quake units),
	// standing on its origin: X/Y +-16, Z from 0 to 64. Non-indexed
	// triangle list (36 verts, 12 tris) - simplest to hardcode directly.
	static const simd_float3 boxVerts[36] = {
		// -Y face
		{ -16, -16, 0 }, { 16, -16, 0 }, { 16, -16, 64 },
		{ -16, -16, 0 }, { 16, -16, 64 }, { -16, -16, 64 },
		// +Y face
		{ 16, 16, 0 }, { -16, 16, 0 }, { -16, 16, 64 },
		{ 16, 16, 0 }, { -16, 16, 64 }, { 16, 16, 64 },
		// -X face
		{ -16, 16, 0 }, { -16, -16, 0 }, { -16, -16, 64 },
		{ -16, 16, 0 }, { -16, -16, 64 }, { -16, 16, 64 },
		// +X face
		{ 16, -16, 0 }, { 16, 16, 0 }, { 16, 16, 64 },
		{ 16, -16, 0 }, { 16, 16, 64 }, { 16, -16, 64 },
		// bottom (-Z)
		{ -16, -16, 0 }, { -16, 16, 0 }, { 16, 16, 0 },
		{ -16, -16, 0 }, { 16, 16, 0 }, { 16, -16, 0 },
		// top (+Z)
		{ -16, 16, 64 }, { -16, -16, 64 }, { 16, -16, 64 },
		{ -16, 16, 64 }, { 16, -16, 64 }, { 16, 16, 64 },
	};
	rtBoxVertexCount = 36;
	rtBoxVertexBuffer = [device newBufferWithBytes:boxVerts length:sizeof( boxVerts ) options:MTLResourceStorageModeShared];

	// One outward normal per face, repeated for each of that face's 6
	// vertices - matches boxVerts' own face-by-face layout exactly, so
	// index i's normal is simply face(i)'s constant outward direction.
	static const simd_float3 boxNormals[36] = {
		{ 0, -1, 0 }, { 0, -1, 0 }, { 0, -1, 0 }, { 0, -1, 0 }, { 0, -1, 0 }, { 0, -1, 0 },
		{ 0, 1, 0 }, { 0, 1, 0 }, { 0, 1, 0 }, { 0, 1, 0 }, { 0, 1, 0 }, { 0, 1, 0 },
		{ -1, 0, 0 }, { -1, 0, 0 }, { -1, 0, 0 }, { -1, 0, 0 }, { -1, 0, 0 }, { -1, 0, 0 },
		{ 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 },
		{ 0, 0, -1 }, { 0, 0, -1 }, { 0, 0, -1 }, { 0, 0, -1 }, { 0, 0, -1 }, { 0, 0, -1 },
		{ 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 },
	};
	rtBoxNormalBuffer = [device newBufferWithBytes:boxNormals length:sizeof( boxNormals ) options:MTLResourceStorageModeShared];

	return true;
}

id<MTLRenderPipelineState> RT_GetPipeline3D( void )
{
	return rtPipeline3D;
}

id<MTLDepthStencilState> RT_GetDepthState3D( void )
{
	return rtDepthState3D;
}

// A single fixed directional "sun" - session 10's honest scope is real
// shading that responds to surface orientation, not yet anything
// derived from a map's actual light entities or BSP lightgrid (that's
// real, separate work). Shared by rt_world.mm so world geometry and
// entities are lit consistently from the same direction.
simd_float3 RT_GetLightDir( void )
{
	return simd_normalize( simd_make_float3( 0.35f, -0.45f, 0.82f ) );
}

// Extracts the rotation-only 3x3 from a 4x4 model matrix, for
// transforming a model-space normal into world space. Valid directly,
// without an inverse-transpose, because RT_BuildModelMatrix's axes are
// always orthonormal (no non-uniform scale ever applied).
simd_float3x3 RT_ModelRotation3x3( simd_float4x4 model )
{
	simd_float3x3 m;
	m.columns[0] = simd_make_float3( model.columns[0].x, model.columns[0].y, model.columns[0].z );
	m.columns[1] = simd_make_float3( model.columns[1].x, model.columns[1].y, model.columns[1].z );
	m.columns[2] = simd_make_float3( model.columns[2].x, model.columns[2].y, model.columns[2].z );
	return m;
}

// See code/renderergl2/tr_main.c R_RotateForViewer's s_flipMatrix comment
// ("convert from our coordinate system (looking down X) to OpenGL's
// coordinate system (looking down -Z)") for the derivation this matches:
// viewaxis[0]=forward, viewaxis[1]=left, viewaxis[2]=up: view-space
// right=-left, up=up, back(-Z direction)=-forward.
simd_float4x4 RT_BuildViewMatrix( const vec3_t vieworg, const vec3_t viewaxis[3] )
{
	simd_float3 forward = simd_make_float3( viewaxis[0][0], viewaxis[0][1], viewaxis[0][2] );
	simd_float3 left = simd_make_float3( viewaxis[1][0], viewaxis[1][1], viewaxis[1][2] );
	simd_float3 up = simd_make_float3( viewaxis[2][0], viewaxis[2][1], viewaxis[2][2] );
	simd_float3 right = -left;
	simd_float3 back = -forward;
	simd_float3 eye = simd_make_float3( vieworg[0], vieworg[1], vieworg[2] );

	simd_float4 row0 = simd_make_float4( right.x, right.y, right.z, -simd_dot( right, eye ) );
	simd_float4 row1 = simd_make_float4( up.x, up.y, up.z, -simd_dot( up, eye ) );
	simd_float4 row2 = simd_make_float4( back.x, back.y, back.z, -simd_dot( back, eye ) );

	simd_float4x4 m;
	m.columns[0] = simd_make_float4( row0.x, row1.x, row2.x, 0 );
	m.columns[1] = simd_make_float4( row0.y, row1.y, row2.y, 0 );
	m.columns[2] = simd_make_float4( row0.z, row1.z, row2.z, 0 );
	m.columns[3] = simd_make_float4( row0.w, row1.w, row2.w, 1 );
	return m;
}

// Standard Metal right-handed perspective, NDC z in [0,1], camera
// looking down -Z (matches RT_BuildViewMatrix above). fov_x/fov_y come
// straight from refdef_t, already separate per axis, so no aspect-ratio
// derivation is needed here.
simd_float4x4 RT_BuildProjectionMatrix( float fovXDeg, float fovYDeg, float nearZ, float farZ )
{
	float xs = 1.0f / tanf( fovXDeg * ( (float)M_PI / 180.0f ) * 0.5f );
	float ys = 1.0f / tanf( fovYDeg * ( (float)M_PI / 180.0f ) * 0.5f );
	float zs = farZ / ( nearZ - farZ );

	simd_float4x4 m;
	m.columns[0] = simd_make_float4( xs, 0, 0, 0 );
	m.columns[1] = simd_make_float4( 0, ys, 0, 0 );
	m.columns[2] = simd_make_float4( 0, 0, zs, -1 );
	m.columns[3] = simd_make_float4( 0, 0, nearZ * zs, 0 );
	return m;
}

// See code/renderergl2/tr_main.c R_RotateForEntity: model-matrix columns
// 0/1/2 are the entity's axis vectors as-is (w=0), column 3 is origin
// (w=1) - a symmetric placeholder box doesn't visually distinguish a
// rotation-convention mistake here, so this isn't independently verified
// live the way the camera convention above was; revisit once a real,
// asymmetric model needs it.
simd_float4x4 RT_BuildModelMatrix( const float origin[3], const float axis[3][3] )
{
	simd_float4x4 m;
	m.columns[0] = simd_make_float4( axis[0][0], axis[0][1], axis[0][2], 0 );
	m.columns[1] = simd_make_float4( axis[1][0], axis[1][1], axis[1][2], 0 );
	m.columns[2] = simd_make_float4( axis[2][0], axis[2][1], axis[2][2], 0 );
	m.columns[3] = simd_make_float4( origin[0], origin[1], origin[2], 1 );
	return m;
}

// Matches a baked mesh surface's name (e.g. "ranger_top") against the
// TIKI-level `surface <name> shader <name>` mappings from the .tik
// script's setup block (dtiki_t::surfaces, a SEPARATE list from the mesh
// geometry surfaces being baked - matched by name, exactly how the real
// renderer's R_InitStaticModels resolves shaders for tr_model.cpp's
// RB_StaticMesh) and tries to resolve its first non-empty shader name to
// a real texture via the same direct-image-file/.shader-script loader
// DrawStretchPic uses. Some real shader names still don't resolve (no
// matching .shader block and not a direct image file - e.g. procedural-
// only stages), so returning nil here is expected, not a bug -
// RT_RenderScene falls back to the flat-magenta pipeline for any
// surface this returns nil for. outBlendMode (session 13) is only
// meaningful when a texture is actually returned.
static id<MTLTexture> RT_ResolveSurfaceTexture( dtiki_t *tiki, const char *surfaceName, rtBlendMode_t *outBlendMode )
{
	for ( int i = 0; i < tiki->num_surfaces; i++ )
	{
		dtikisurface_t *tikiSurf = &tiki->surfaces[i];
		if ( Q_stricmp( tikiSurf->name, surfaceName ) != 0 )
			continue;

		for ( int k = 0; k < MAX_TIKI_SHADER; k++ )
		{
			if ( tikiSurf->shader[k][0] == '\0' )
				continue;

			qhandle_t handle = RT_RegisterImageCommon( tikiSurf->shader[k] );
			if ( handle != 0 )
			{
				if ( outBlendMode != NULL )
					*outBlendMode = RT_GetImageBlendMode( handle );
				return RT_GetImageTexture( handle );
			}
		}
		break;
	}
	return nil;
}

// Bakes a dtiki_t's mesh data into one shared vertex/texcoord/index
// buffer set (one draw range + texture per real mesh surface), in the
// model's idle/frame-0 pose - no runtime skinning, no per-frame
// animation, matching the real renderer's own R_InitStaticModels
// (code/renderergl2/tr_staticmodels.cpp), which does the same one-time
// bake for non-animating map props. That function only reads each
// vertex's FIRST bone weight, which is only correct when a vertex has a
// single 1.0-weight bone (true for most static-prop meshes, wrong for
// anything smoothly multi-weighted); this sums over every weight instead,
// matching the fully-correct animated path's SkelWeightGetXyz
// (tr_model.cpp) - the small extra loop costs nothing at load time.
static void RT_BakeTikiModel( dtiki_t *tiki, rtModel_t *model )
{
	model->vertexBuffer = nil;
	model->texcoordBuffer = nil;
	model->normalBuffer = nil;
	model->indexBuffer = nil;
	model->indexCount = 0;
	model->numSurfaces = 0;

	if ( tiki == NULL || tiki->numMeshes <= 0 )
		return;

	skelBoneCache_t bones[128];
	float radius;
	vec3_t mins, maxs;
	ri.TIKI_GetSkelAnimFrame( tiki, bones, &radius, &mins, &maxs );

	std::vector<simd_float3> verts;
	std::vector<simd_float2> texcoords;
	std::vector<simd_float3> normals;
	std::vector<uint32_t> indices;

	for ( int meshIndex = 0; meshIndex < tiki->numMeshes; meshIndex++ )
	{
		skelHeaderGame_t *skelmodel = ri.TIKI_GetSkel( tiki->mesh[meshIndex] );
		if ( skelmodel == NULL )
			continue;

		skelSurfaceGame_t *surf = skelmodel->pSurfaces;
		for ( int s = 0; s < skelmodel->numSurfaces && surf != NULL; s++, surf = surf->pNext )
		{
			int baseVertex = (int)verts.size();
			skeletorVertex_t *vert = surf->pVerts;

			for ( int v = 0; v < surf->numVerts; v++ )
			{
				skelWeight_t *weight = (skelWeight_t *)( (byte *)vert + sizeof( skeletorVertex_t )
					+ vert->numMorphs * sizeof( skeletorMorph_t ) );

				vec3_t out = { 0.0f, 0.0f, 0.0f };
				int firstBoneNum = -1;
				for ( int w = 0; w < vert->numWeights; w++ )
				{
					// Multiple meshes in one TIKI can share a skeleton
					// via a channel indirection rather than a direct
					// bone index - mesh 0 doesn't need it, matching
					// R_InitStaticModels' identical branch.
					int boneNum;
					if ( meshIndex > 0 )
					{
						int channel = skelmodel->pBones[weight->boneIndex].channel;
						boneNum = ri.TIKI_GetLocalChannel( tiki, channel );
					}
					else
					{
						boneNum = weight->boneIndex;
					}
					if ( w == 0 )
						firstBoneNum = boneNum;

					skelBoneCache_t *bone = &bones[boneNum];
					out[0] += ( ( weight->offset[0] * bone->matrix[0][0] + weight->offset[1] * bone->matrix[1][0]
						+ weight->offset[2] * bone->matrix[2][0] ) + bone->offset[0] ) * weight->boneWeight;
					out[1] += ( ( weight->offset[0] * bone->matrix[0][1] + weight->offset[1] * bone->matrix[1][1]
						+ weight->offset[2] * bone->matrix[2][1] ) + bone->offset[1] ) * weight->boneWeight;
					out[2] += ( ( weight->offset[0] * bone->matrix[0][2] + weight->offset[1] * bone->matrix[1][2]
						+ weight->offset[2] * bone->matrix[2][2] ) + bone->offset[2] ) * weight->boneWeight;

					weight++;
				}

				verts.push_back( simd_make_float3(
					out[0] * tiki->load_scale, out[1] * tiki->load_scale, out[2] * tiki->load_scale ) );
				texcoords.push_back( simd_make_float2( vert->texCoords[0], vert->texCoords[1] ) );

				// Normal: the real renderer's SkelVertGetNormal
				// (tr_model.cpp) transforms by only the vertex's FIRST
				// weight's bone rotation, never summed across weights
				// like position - true even in the fully-correct
				// animated path, so this matches established behavior
				// rather than being a shortcut.
				if ( firstBoneNum >= 0 )
				{
					skelBoneCache_t *bone = &bones[firstBoneNum];
					simd_float3 n;
					n.x = vert->normal[0] * bone->matrix[0][0] + vert->normal[1] * bone->matrix[1][0]
						+ vert->normal[2] * bone->matrix[2][0];
					n.y = vert->normal[0] * bone->matrix[0][1] + vert->normal[1] * bone->matrix[1][1]
						+ vert->normal[2] * bone->matrix[2][1];
					n.z = vert->normal[0] * bone->matrix[0][2] + vert->normal[1] * bone->matrix[1][2]
						+ vert->normal[2] * bone->matrix[2][2];
					normals.push_back( n );
				}
				else
				{
					normals.push_back( simd_make_float3( 0.0f, 0.0f, 1.0f ) );
				}

				vert = (skeletorVertex_t *)( (byte *)vert + sizeof( skeletorVertex_t )
					+ sizeof( skeletorMorph_t ) * vert->numMorphs
					+ sizeof( skelWeight_t ) * vert->numWeights );
			}

			uint32_t baseIndex = (uint32_t)indices.size();
			skelIndex_t *tri = surf->pTriangles;
			for ( int t = 0; t < surf->numTriangles * 3; t++ )
				indices.push_back( (uint32_t)( baseVertex + tri[t] ) );
			uint32_t surfIndexCount = (uint32_t)indices.size() - baseIndex;

			if ( surfIndexCount > 0 )
			{
				if ( model->numSurfaces < MAX_RT_MODEL_SURFACES )
				{
					rtModelSurface_t *modelSurf = &model->surfaces[model->numSurfaces++];
					modelSurf->indexOffset = baseIndex;
					modelSurf->indexCount = surfIndexCount;
					modelSurf->blendMode = RT_BLEND_OPAQUE;
					modelSurf->texture = RT_ResolveSurfaceTexture( tiki, surf->name, &modelSurf->blendMode );
				}
				else
				{
					ri.Printf( PRINT_WARNING, "renderer_metalrt: RegisterModel: \"%s\" hit "
						"MAX_RT_MODEL_SURFACES (%d), dropping surface \"%s\"\n",
						tiki->name, MAX_RT_MODEL_SURFACES, surf->name );
				}
			}
		}
	}

	if ( verts.empty() || indices.empty() )
	{
		model->numSurfaces = 0;
		return;
	}

	model->vertexBuffer = [RT_GetDevice() newBufferWithBytes:verts.data()
	                                                    length:verts.size() * sizeof( simd_float3 )
	                                                   options:MTLResourceStorageModeShared];
	model->texcoordBuffer = [RT_GetDevice() newBufferWithBytes:texcoords.data()
	                                                      length:texcoords.size() * sizeof( simd_float2 )
	                                                     options:MTLResourceStorageModeShared];
	model->normalBuffer = [RT_GetDevice() newBufferWithBytes:normals.data()
	                                                    length:normals.size() * sizeof( simd_float3 )
	                                                   options:MTLResourceStorageModeShared];
	model->indexBuffer = [RT_GetDevice() newBufferWithBytes:indices.data()
	                                                   length:indices.size() * sizeof( uint32_t )
	                                                  options:MTLResourceStorageModeShared];
	model->indexCount = (int)indices.size();
}

// Shared by RegisterModel/RegisterServerModel/SpawnEffectModel - the real
// renderer funnels all three through one R_RegisterModelInternal
// (tr_model.cpp) for the same reason: it's the identical registration
// contract, just reached from different game-code contexts
// (client-registered vs. server-preloaded vs. a one-shot effect that
// registers-and-spawns in the same call).
static qhandle_t RT_RegisterModelInternal( const char *name )
{
	if ( !name || !name[0] )
		return 0;

	for ( int i = 1; i <= numRtModels; i++ )
	{
		if ( !Q_stricmp( rtModels[i].name, name ) )
			return i;
	}

	const char *ext = COM_GetExtension( name );
	if ( Q_stricmp( ext, "tik" ) != 0 )
	{
		// Sprites (.spr) and anything else real content uses are a
		// separate, later session - see tr_model.cpp's real dispatch
		// (".spr" -> MOD_SPRITE, ".tik" -> MOD_TIKI) for the actual
		// scope once this needs to grow beyond TIKI models.
		RT_STUB_ONCE();
		return 0;
	}

	// ri.TIKI_RegisterTikiFlags is the same client-side entry point the
	// real renderer's R_RegisterModelInternal uses - a full text .tik +
	// binary .skd parse (PK3-aware; it's backed by the same FS_ReadFile
	// this file used to call directly for a bare existence check before
	// this session). Returns NULL on any parse/file failure.
	dtiki_t *tiki = ri.TIKI_RegisterTikiFlags( name, qfalse );
	if ( tiki == NULL )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: RegisterModel: \"%s\" failed to load\n", name );
		return 0;
	}

	if ( numRtModels + 1 >= MAX_RT_MODELS )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: RegisterModel: MAX_RT_MODELS (%d) hit, dropping \"%s\"\n",
			MAX_RT_MODELS, name );
		return 0;
	}

	numRtModels++;
	rtModel_t *model = &rtModels[numRtModels];
	Q_strncpyz( model->name, name, sizeof( model->name ) );
	RT_BakeTikiModel( tiki, model );

	if ( model->vertexBuffer != nil )
	{
		ri.Printf( PRINT_DEVELOPER, "renderer_metalrt: registered model \"%s\" -> handle %d "
			"(%d real indices baked)\n", name, numRtModels, model->indexCount );
	}
	else
	{
		ri.Printf( PRINT_DEVELOPER, "renderer_metalrt: registered model \"%s\" -> handle %d "
			"(placeholder box - no mesh data to bake)\n", name, numRtModels );
	}

	return numRtModels;
}

static qhandle_t RT_RegisterModel( const char *name )
{
	return RT_RegisterModelInternal( name );
}

static qhandle_t RT_RegisterServerModel( const char *name )
{
	return RT_RegisterModelInternal( name );
}

// Registers a model AND immediately submits a one-shot placeholder
// entity at the given position/orientation - mirrors RE_SpawnEffectModel
// (tr_model.cpp), which does the same (register, then hand the new
// entity straight to CG_ProcessInitCommands) rather than waiting for a
// separate AddRefEntityToScene call.
static qhandle_t RT_SpawnEffectModel( const char *name, vec3_t pos, vec3_t axis[3] )
{
	qhandle_t handle = RT_RegisterModelInternal( name );
	if ( handle == 0 )
		return 0;

	if ( numRtSceneEntities < MAX_RT_SCENE_ENTITIES )
	{
		rtSceneEntity_t *entity = &rtSceneEntities[numRtSceneEntities++];
		VectorCopy( pos, entity->origin );
		if ( axis )
		{
			for ( int i = 0; i < 3; i++ )
				VectorCopy( axis[i], entity->axis[i] );
		}
		else
		{
			AxisClear( entity->axis );
		}
		entity->hModel = handle;
	}

	return handle;
}

static void RT_ClearScene( void )
{
	numRtSceneEntities = 0;
}

static void RT_AddRefEntityToScene( const refEntity_t *re, int parentEntityNumber )
{
	if ( re->reType != RT_MODEL )
		return;

	if ( re->hModel <= 0 || re->hModel > numRtModels )
		return;

	if ( numRtSceneEntities >= MAX_RT_SCENE_ENTITIES )
		return;

	{
		static bool loggedOnce = false;
		if ( !loggedOnce )
		{
			loggedOnce = true;
			ri.Printf( PRINT_DEVELOPER, "renderer_metalrt: AddRefEntityToScene: first valid RT_MODEL "
				"entity (model \"%s\") at origin (%.1f %.1f %.1f)\n",
				rtModels[re->hModel].name, re->origin[0], re->origin[1], re->origin[2] );
		}
	}

	rtSceneEntity_t *entity = &rtSceneEntities[numRtSceneEntities++];
	VectorCopy( re->origin, entity->origin );
	for ( int i = 0; i < 3; i++ )
		VectorCopy( re->axis[i], entity->axis[i] );
	entity->hModel = re->hModel;
}

// rt_world.mm - reuses this file's shared 3D pipeline/depth state
// (RT_GetPipeline3D/RT_GetDepthState3D/RT_EnsurePipeline3D) rather than
// standing up a second, near-identical one for world geometry.
void RT_DrawWorld( simd_float4x4 viewProj );

static void RT_RenderScene( const refdef_t *fd )
{
	if ( !RT_EnsurePipeline3D() )
		return;

	id<MTLRenderCommandEncoder> encoder = RT_GetCurrentEncoder();
	if ( encoder == nil )
		return;

	// Reasonable placeholder near/far - refdef_t doesn't carry these
	// directly in this fork (farplane_distance is fog, not a hard clip
	// plane); revisit once real world geometry needs a principled value.
	const float nearZ = 4.0f;
	const float farZ = 8192.0f;

	simd_float4x4 view = RT_BuildViewMatrix( fd->vieworg, fd->viewaxis );
	simd_float4x4 proj = RT_BuildProjectionMatrix( fd->fov_x, fd->fov_y, nearZ, farZ );
	simd_float4x4 viewProj = simd_mul( proj, view );

	// World geometry first (see rt_world.mm) - it's the background;
	// entity placeholders draw on top of it, correctly depth-tested
	// against it either way since both go through the same depth state.
	RT_DrawWorld( viewProj );

	if ( numRtSceneEntities == 0 )
		return;

	// Session 7: real per-surface textures where a surface's shader name
	// resolved to one (see RT_ResolveSurfaceTexture) - degrades cleanly
	// to the flat pipeline for this whole frame if the textured pipeline
	// itself somehow fails to compile (kept as a real, checked failure
	// path rather than assumed to always succeed).
	bool haveTexturedPipeline = RT_EnsurePipelineTextured3D();

	// Deliberately garish, unmissable placeholder color for any surface
	// with no resolvable texture (most .shader-script names still don't
	// resolve, see rt_image.mm's "no .shader script support yet"
	// warning) and for any model that failed to bake real geometry at
	// all (draws the box fallback instead) - not meant to be mistaken
	// for final art either way.
	simd_float4 entityColor = simd_make_float4( 1.0f, 0.0f, 1.0f, 1.0f );
	simd_float3 lightDir = RT_GetLightDir();

	for ( int i = 0; i < numRtSceneEntities; i++ )
	{
		simd_float4x4 model = RT_BuildModelMatrix( rtSceneEntities[i].origin, rtSceneEntities[i].axis );
		simd_float4x4 mvp = simd_mul( viewProj, model );
		simd_float3x3 normalMatrix = RT_ModelRotation3x3( model );

		qhandle_t hModel = rtSceneEntities[i].hModel;
		rtModel_t *m = ( hModel >= 1 && hModel <= numRtModels ) ? &rtModels[hModel] : NULL;

		if ( m != NULL && m->vertexBuffer != nil && m->indexBuffer != nil && m->numSurfaces > 0 )
		{
			for ( int s = 0; s < m->numSurfaces; s++ )
			{
				rtModelSurface_t *surf = &m->surfaces[s];

				if ( surf->texture != nil && haveTexturedPipeline )
				{
					// Session 13: pick the pipeline variant (and its
					// matching depth state - blended surfaces don't
					// write depth) by this surface's resolved blend
					// mode. All three share the same shader/vertex-
					// buffer bindings, just a different PSO/depth state.
					id<MTLRenderPipelineState> pipeline = rtPipelineTextured3D;
					id<MTLDepthStencilState> depthState = rtDepthState3D;
					if ( surf->blendMode == RT_BLEND_ALPHA )
					{
						pipeline = rtPipelineTexturedAlpha3D;
						depthState = rtDepthStateBlended3D;
					}
					else if ( surf->blendMode == RT_BLEND_ADDITIVE )
					{
						pipeline = rtPipelineTexturedAdditive3D;
						depthState = rtDepthStateBlended3D;
					}
					else if ( surf->blendMode == RT_BLEND_ALPHATEST )
					{
						pipeline = rtPipelineTexturedAlphaTest3D;
						// depthState stays rtDepthState3D (opaque/write) -
						// see RT_DrawTexturedGeometry's identical case.
					}

					[encoder setRenderPipelineState:pipeline];
					[encoder setDepthStencilState:depthState];
					[encoder setVertexBuffer:m->vertexBuffer offset:0 atIndex:0];
					[encoder setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];
					[encoder setVertexBuffer:m->texcoordBuffer offset:0 atIndex:2];
					[encoder setVertexBuffer:m->normalBuffer offset:0 atIndex:3];
					[encoder setVertexBytes:&normalMatrix length:sizeof( normalMatrix ) atIndex:4];
					[encoder setFragmentTexture:surf->texture atIndex:0];
					[encoder setFragmentSamplerState:rtSamplerTextured3D atIndex:0];
					[encoder setFragmentBytes:&lightDir length:sizeof( lightDir ) atIndex:0];
				}
				else
				{
					[encoder setRenderPipelineState:rtPipeline3D];
					[encoder setDepthStencilState:rtDepthState3D];
					[encoder setVertexBuffer:m->vertexBuffer offset:0 atIndex:0];
					[encoder setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];
					[encoder setVertexBuffer:m->normalBuffer offset:0 atIndex:2];
					[encoder setVertexBytes:&normalMatrix length:sizeof( normalMatrix ) atIndex:3];
					[encoder setFragmentBytes:&entityColor length:sizeof( entityColor ) atIndex:0];
					[encoder setFragmentBytes:&lightDir length:sizeof( lightDir ) atIndex:1];
				}

				[encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
				                     indexCount:surf->indexCount
				                      indexType:MTLIndexTypeUInt32
				                    indexBuffer:m->indexBuffer
				              indexBufferOffset:surf->indexOffset * sizeof( uint32_t )];
			}
		}
		else
		{
			[encoder setRenderPipelineState:rtPipeline3D];
			[encoder setDepthStencilState:rtDepthState3D];
			[encoder setVertexBuffer:rtBoxVertexBuffer offset:0 atIndex:0];
			[encoder setVertexBytes:&mvp length:sizeof( mvp ) atIndex:1];
			[encoder setVertexBuffer:rtBoxNormalBuffer offset:0 atIndex:2];
			[encoder setVertexBytes:&normalMatrix length:sizeof( normalMatrix ) atIndex:3];
			[encoder setFragmentBytes:&entityColor length:sizeof( entityColor ) atIndex:0];
			[encoder setFragmentBytes:&lightDir length:sizeof( lightDir ) atIndex:1];
			[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:rtBoxVertexCount];
		}
	}
}

// Session 19: rtModel_t has stored its registration name (RT_RegisterModelInternal)
// since session 6 - this was a loud stub always returning "" for no
// reason other than never being wired up. Pure accessor, no interaction
// with the render path.
const char *RT_GetModelName( qhandle_t hModel )
{
	if ( hModel <= 0 || hModel > numRtModels )
		return "";
	return rtModels[hModel].name;
}

void RT_InitSceneFunctions( refexport_t *re )
{
	re->RegisterModel = RT_RegisterModel;
	re->RegisterServerModel = RT_RegisterServerModel;
	re->SpawnEffectModel = RT_SpawnEffectModel;
	re->ClearScene = RT_ClearScene;
	re->AddRefEntityToScene = RT_AddRefEntityToScene;
	re->RenderScene = RT_RenderScene;
	re->GetModelName = RT_GetModelName;
}

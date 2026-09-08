/*
===========================================================================
tr_metal_overlay.mm - real-time ray-traced shadow overlay for the Metal
(ANGLE) renderer target only (see cmake/renderer_metal.cmake - this file
is not built into renderer_opengl1/2 or the dedicated server).

Architecture: renderer_metal already renders the full, correct scene via
ANGLE translating GL2's real, unmodified GLES3 calls directly to Metal
(see sdl_metalimp.c). That pipeline is NOT touched here - no changes to
the EGL surface/context/swap path, which stays exactly as proven working
before this file existed. Instead, this adds a SEPARATE, independent
CAMetalLayer as a sibling sublayer directly above ANGLE's own Metal
layer, composited by the window server (standard, zero-risk OS-level
layer compositing - no exotic ANGLE interop needed). Each frame, a real
hardware ray-traced compute pass writes semi-transparent black into this
overlay layer wherever a traced shadow ray from that pixel's real
world-space position (found via a primary ray against the same
acceleration structure) is occluded from the light - everywhere else is
fully transparent, letting ANGLE's own rendering show through completely
unchanged. This was chosen over an offscreen-client-buffer + full
pixel-level compositing approach specifically because ANGLE's Metal
texture client-buffer extension has no usage example anywhere in this
vendored copy to verify against, and getting it wrong risks breaking the
one rendering path already proven correct, with no one available
overnight to help debug it. This overlay approach can't do full
multiplicative shadow darkening or true reflections, but it delivers a
real, correct, first ray-traced enhancement layered on top of GL2's
correct rendering - proving the "ANGLE base + ray-traced enhancement on
top" architecture end to end before attempting anything riskier.

World geometry comes from tr.world (msurface_t/srfBspSurface_t) - GL2's
own already-tessellated, already-correct surface data (real lightmap
UVs, real Bezier-tessellated patches, real terrain LOD mesh where
applicable) - not a re-parse of the raw BSP file. This was the entire
point of building on top of GL2 instead of renderer_metalrt's from-
scratch approach: zero format reverse-engineering risk this time.
===========================================================================
*/
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>
#include <simd/simd.h>

#include <vector>

// Not wrapped in extern "C" - tr_local.h transitively includes real C++
// standard headers (q_shared.h -> <chrono>), and templates can't have C
// linkage. tr_local.h is already safe to include directly from C++ (see
// tr_model.cpp/tr_font.cpp etc. in this same renderer). Only this
// file's OWN functions below need extern "C" (matching how sdl_metalimp.c,
// a plain .c file, declares and calls them).
#include "tr_local.h"

namespace {

id<MTLDevice> rtoDevice = nil;
id<MTLCommandQueue> rtoQueue = nil;
CAMetalLayer *rtoLayer = nil;
CAMetalLayer *rtoBaseLayer = nil; // ANGLE's own layer; re-checked each frame until it has a superlayer (see RTO_EnsureAttached)

id<MTLAccelerationStructure> rtoAccelStructure = nil;
id<MTLBuffer> rtoPositionBuffer = nil;
int rtoTriangleCount = 0;

id<MTLComputePipelineState> rtoPipeline = nil;

bool rtoHaveCamera = false;
simd_float3 rtoOrigin, rtoForward, rtoRight, rtoUp;
float rtoTanHalfFovX = 1.0f, rtoTanHalfFovY = 1.0f;

const char *rtoShaderSource =
	"#include <metal_stdlib>\n"
	"#include <metal_raytracing>\n"
	"using namespace metal;\n"
	"using namespace raytracing;\n"
	"struct RTOCamera {\n"
	"    float3 origin;\n"
	"    float3 forward;\n"
	"    float3 right;\n"
	"    float3 up;\n"
	"    float tanHalfFovX;\n"
	"    float tanHalfFovY;\n"
	"    float3 lightDir;\n"
	"};\n"
	"kernel void rto_shadow_overlay(\n"
	"    uint2 tid [[thread_position_in_grid]],\n"
	"    texture2d<float, access::write> outTex [[texture(0)]],\n"
	"    constant RTOCamera &camera [[buffer(0)]],\n"
	"    const device float3 *positions [[buffer(1)]],\n"
	"    primitive_acceleration_structure accelStruct [[buffer(2)]]) {\n"
	"    uint w = outTex.get_width();\n"
	"    uint h = outTex.get_height();\n"
	"    if (tid.x >= w || tid.y >= h) return;\n"
	"\n"
	"    float2 uv = (float2(tid) + 0.5) / float2(w, h);\n"
	"    float2 ndc = uv * 2.0 - 1.0;\n"
	"    ndc.y = -ndc.y;\n"
	"    float3 dir = normalize(camera.forward + camera.right * (ndc.x * camera.tanHalfFovX)\n"
	"        + camera.up * (ndc.y * camera.tanHalfFovY));\n"
	"\n"
	"    ray r;\n"
	"    r.origin = camera.origin;\n"
	"    r.direction = dir;\n"
	"    r.min_distance = 1.0;\n"
	"    r.max_distance = 65536.0;\n"
	"\n"
	"    intersector<triangle_data> isect;\n"
	"    intersection_result<triangle_data> result = isect.intersect(r, accelStruct);\n"
	"\n"
	"    if (result.type == intersection_type::none) {\n"
	"        outTex.write(float4(0.0, 0.0, 0.0, 0.0), tid);\n"
	"        return;\n"
	"    }\n"
	"\n"
	"    uint primIdx = result.primitive_id;\n"
	"    float3 v0 = positions[primIdx * 3 + 0];\n"
	"    float3 v1 = positions[primIdx * 3 + 1];\n"
	"    float3 v2 = positions[primIdx * 3 + 2];\n"
	"    float3 normal = normalize(cross(v1 - v0, v2 - v0));\n"
	"    float3 hitPoint = r.origin + r.direction * result.distance;\n"
	"\n"
	"    ray shadowRay;\n"
	"    shadowRay.origin = hitPoint + normal * 2.0;\n"
	"    shadowRay.direction = camera.lightDir;\n"
	"    shadowRay.min_distance = 1.0;\n"
	"    shadowRay.max_distance = 65536.0;\n"
	"    intersection_result<triangle_data> shadowResult = isect.intersect(shadowRay, accelStruct);\n"
	"\n"
	"    if (shadowResult.type != intersection_type::none) {\n"
	"        outTex.write(float4(0.0, 0.0, 0.0, 0.55), tid);\n"
	"    } else {\n"
	"        outTex.write(float4(0.0, 0.0, 0.0, 0.0), tid);\n"
	"    }\n"
	"}\n";

bool RTO_EnsurePipeline( void )
{
	if ( rtoPipeline != nil )
		return true;
	if ( !rtoDevice.supportsRaytracing )
	{
		ri.Printf( PRINT_WARNING, "tr_metal_overlay: device does not support ray tracing - shadow overlay disabled\n" );
		return false;
	}

	NSError *error = nil;
	id<MTLLibrary> library = [rtoDevice newLibraryWithSource:[NSString stringWithUTF8String:rtoShaderSource]
	                                                   options:nil
	                                                     error:&error];
	if ( library == nil )
	{
		ri.Printf( PRINT_WARNING, "tr_metal_overlay: failed to compile shadow overlay kernel: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	id<MTLFunction> fn = [library newFunctionWithName:@"rto_shadow_overlay"];
	rtoPipeline = [rtoDevice newComputePipelineStateWithFunction:fn error:&error];
	if ( rtoPipeline == nil )
	{
		ri.Printf( PRINT_WARNING, "tr_metal_overlay: failed to create shadow overlay pipeline: %s\n",
			error ? [[error localizedDescription] UTF8String] : "unknown error" );
		return false;
	}

	return true;
}

// SDL_Metal_GetLayer's CAMetalLayer has no superlayer yet at RT_OverlayInit
// time (the backing NSView isn't attached to the window's view hierarchy
// that early in sdl_metalimp.c's init sequence), so addSublayer there is a
// silent no-op and the overlay never actually composites - confirmed via a
// one-frame flood-fill-magenta test that produced zero visible pixels even
// though the compute dispatch itself was running correctly every frame.
// Retrying each frame until the base layer is really in the tree is simple
// and robust without needing to know SDL's internal ordering.
bool RTO_EnsureAttached( void )
{
	if ( rtoLayer.superlayer != nil )
		return true;
	if ( rtoBaseLayer == nil || rtoBaseLayer.superlayer == nil )
		return false;

	rtoLayer.frame = rtoBaseLayer.frame;
	rtoLayer.contentsScale = rtoBaseLayer.contentsScale;
	rtoLayer.drawableSize = rtoBaseLayer.drawableSize;
	rtoLayer.zPosition = rtoBaseLayer.zPosition + 1.0f;
	[rtoBaseLayer.superlayer addSublayer:rtoLayer];

	ri.Printf( PRINT_ALL, "tr_metal_overlay: shadow overlay layer attached to window (superlayer now %p)\n",
		(void*)rtoLayer.superlayer );
	return rtoLayer.superlayer != nil;
}

} // namespace

extern "C" void RT_OverlayInit( void *sdlMetalLayer )
{
	if ( sdlMetalLayer == NULL )
		return;

	CAMetalLayer *baseLayer = (__bridge CAMetalLayer *)sdlMetalLayer;

	rtoDevice = MTLCreateSystemDefaultDevice();
	if ( rtoDevice == nil )
	{
		ri.Printf( PRINT_WARNING, "tr_metal_overlay: MTLCreateSystemDefaultDevice failed - shadow overlay disabled\n" );
		return;
	}
	rtoQueue = [rtoDevice newCommandQueue];

	rtoLayer = [CAMetalLayer layer];
	rtoLayer.device = rtoDevice;
	rtoLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	rtoLayer.framebufferOnly = NO; // the compute kernel writes directly into the drawable's texture
	rtoLayer.opaque = NO; // alpha=0 pixels must show ANGLE's real rendering underneath
	rtoLayer.frame = baseLayer.frame;
	rtoLayer.contentsScale = baseLayer.contentsScale;
	rtoLayer.drawableSize = baseLayer.drawableSize;
	rtoLayer.zPosition = baseLayer.zPosition + 1.0f;

	rtoBaseLayer = baseLayer;
	RTO_EnsureAttached(); // best-effort now; retried every frame in RT_OverlayRenderAndPresent until it takes

	ri.Printf( PRINT_ALL, "tr_metal_overlay: real-time ray-traced shadow overlay layer created (device: %s)\n",
		[rtoDevice.name UTF8String] );
}

// Called once after RE_LoadWorldMap populates tr.world - walks the SAME
// already-tessellated, already-correct surface data GL2's own rendering
// uses (msurface_t -> srfBspSurface_t for MST_FACE/GRID/TRIANGLES/POLY),
// flattened into one non-indexed triangle position buffer (matching
// each surface's own numIndexes/indexes into its own numVerts/verts -
// simplest correct thing, not the fastest possible layout). Terrain
// (SF_TERRAIN_PATCH) is real, separate follow-up work - it's
// dynamically re-tessellated per-frame by GL2's own ROAM-style LOD
// system (tr_terrain.c), not a static buffer this first pass can just
// grab once, so shadows won't yet account for terrain occluding or
// receiving them.
extern "C" void RT_OverlayBuildWorldAccelStructure( void )
{
	rtoAccelStructure = nil;
	rtoPositionBuffer = nil;
	rtoTriangleCount = 0;

	if ( rtoDevice == nil || tr.world == NULL )
		return;

	std::vector<simd_float3> positions;

	for ( int i = 0; i < tr.world->numsurfaces; i++ )
	{
		msurface_t *surf = &tr.world->surfaces[i];
		if ( surf->data == NULL )
			continue;
		// Sky faces are real BSP geometry (the "hole" in the level where
		// the skybox shows through) but should never occlude or receive
		// shadows - including them made primary rays hit the sky-hole
		// polygon itself and mark it "in shadow", drawing hard-edged dark
		// silhouettes over the sky (found via a screenshot comparison
		// showing flat polygon-shaped dark patches exactly matching sky
		// openings).
		if ( surf->shader != NULL && surf->shader->isSky )
			continue;
		// SURF_NODRAW faces (trigger/clip/structural helper brushes kept
		// only for movement collision) are invisible in GL2's own
		// rendering, but ParseFace/ParseTriSurf in tr_bsp.c build their
		// full geometry regardless (only ParseMesh redirects nodraw
		// patches to SF_SKIP) - including them here produced a stray
		// hard-edged dark polygon slicing across the scene with no
		// corresponding visible surface, found the same way as the sky
		// artifact above.
		if ( surf->shader != NULL && ( surf->shader->surfaceFlags & SURF_NODRAW ) )
			continue;
		// Alpha-tested "cutout" surfaces (foliage/hedges/fences - MoHAA's
		// trees are simple flat quads whose leafy silhouette comes
		// entirely from a per-pixel alpha-tested texture, not the
		// underlying triangle shape). Pure geometric ray tracing has no
		// idea about that texture, so it treated the whole flat quad as
		// solid - a screenshot with primary-ray hits visualized showed
		// big hard-edged rectangles standing in for what should have been
		// individual tree canopies. Rather than draw confidently wrong
		// blocky shadows, skip these surfaces for this first pass -
		// proper alpha-test-aware traversal is real follow-up work, not
		// something to guess at overnight with no one available to check
		// the result.
		if ( surf->shader != NULL && surf->shader->numUnfoggedPasses > 0 && surf->shader->stages[0] != NULL
			&& ( surf->shader->stages[0]->stateBits & GLS_ATEST_BITS ) )
			continue;

		surfaceType_t type = *(surfaceType_t *)surf->data;
		if ( type != SF_FACE && type != SF_GRID && type != SF_TRIANGLES && type != SF_POLY )
			continue;

		srfBspSurface_t *bspSurf = (srfBspSurface_t *)surf->data;
		if ( bspSurf->indexes == NULL || bspSurf->verts == NULL )
			continue;

		for ( int j = 0; j + 2 < bspSurf->numIndexes; j += 3 )
		{
			glIndex_t i0 = bspSurf->indexes[j + 0];
			glIndex_t i1 = bspSurf->indexes[j + 1];
			glIndex_t i2 = bspSurf->indexes[j + 2];
			if ( (int)i0 >= bspSurf->numVerts || (int)i1 >= bspSurf->numVerts || (int)i2 >= bspSurf->numVerts )
				continue;

			const float *p0 = bspSurf->verts[i0].xyz;
			const float *p1 = bspSurf->verts[i1].xyz;
			const float *p2 = bspSurf->verts[i2].xyz;
			positions.push_back( simd_make_float3( p0[0], p0[1], p0[2] ) );
			positions.push_back( simd_make_float3( p1[0], p1[1], p1[2] ) );
			positions.push_back( simd_make_float3( p2[0], p2[1], p2[2] ) );
		}
	}

	if ( positions.size() < 3 )
	{
		ri.Printf( PRINT_ALL, "tr_metal_overlay: no static surface geometry found - shadow overlay has nothing to trace against\n" );
		return;
	}

	rtoPositionBuffer = [rtoDevice newBufferWithBytes:positions.data()
	                                            length:positions.size() * sizeof( simd_float3 )
	                                           options:MTLResourceStorageModeShared];

	MTLAccelerationStructureTriangleGeometryDescriptor *geomDesc =
		[MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
	geomDesc.vertexBuffer = rtoPositionBuffer;
	geomDesc.vertexStride = sizeof( simd_float3 );
	geomDesc.triangleCount = positions.size() / 3;

	MTLPrimitiveAccelerationStructureDescriptor *accelDesc =
		[MTLPrimitiveAccelerationStructureDescriptor descriptor];
	accelDesc.geometryDescriptors = @[ geomDesc ];

	MTLAccelerationStructureSizes sizes = [rtoDevice accelerationStructureSizesWithDescriptor:accelDesc];
	rtoAccelStructure = [rtoDevice newAccelerationStructureWithSize:sizes.accelerationStructureSize];
	id<MTLBuffer> scratchBuffer = [rtoDevice newBufferWithLength:sizes.buildScratchBufferSize
	                                                       options:MTLResourceStorageModePrivate];

	id<MTLCommandBuffer> cmdBuf = [rtoQueue commandBuffer];
	id<MTLAccelerationStructureCommandEncoder> accelEncoder = [cmdBuf accelerationStructureCommandEncoder];
	[accelEncoder buildAccelerationStructure:rtoAccelStructure
	                               descriptor:accelDesc
	                            scratchBuffer:scratchBuffer
	                      scratchBufferOffset:0];
	[accelEncoder endEncoding];
	[cmdBuf commit];
	[cmdBuf waitUntilCompleted]; // one-time build at map load, same as GL2's own VBO uploads

	rtoTriangleCount = (int)( positions.size() / 3 );
	ri.Printf( PRINT_ALL, "tr_metal_overlay: built shadow overlay acceleration structure (%d triangles from static world surfaces)\n",
		rtoTriangleCount );
}

extern "C" void RT_OverlayUpdateCamera( const refdef_t *fd )
{
	if ( fd == NULL )
	{
		rtoHaveCamera = false;
		return;
	}

	rtoOrigin = simd_make_float3( fd->vieworg[0], fd->vieworg[1], fd->vieworg[2] );
	rtoForward = simd_make_float3( fd->viewaxis[0][0], fd->viewaxis[0][1], fd->viewaxis[0][2] );
	simd_float3 left = simd_make_float3( fd->viewaxis[1][0], fd->viewaxis[1][1], fd->viewaxis[1][2] );
	rtoRight = -left;
	rtoUp = simd_make_float3( fd->viewaxis[2][0], fd->viewaxis[2][1], fd->viewaxis[2][2] );
	rtoTanHalfFovX = tanf( fd->fov_x * ( (float)M_PI / 180.0f ) * 0.5f );
	rtoTanHalfFovY = tanf( fd->fov_y * ( (float)M_PI / 180.0f ) * 0.5f );
	rtoHaveCamera = true;
}

extern "C" void RT_OverlayRenderAndPresent( void )
{
	// Live toggle for direct, same-build, same-vantage-point A/B
	// comparison against plain ANGLE/GL2 rendering - not a maintained
	// permanent option, just a way to verify what this layer is
	// actually contributing without needing two separate builds.
	static cvar_t *r_metalShadowOverlay = NULL;
	if ( r_metalShadowOverlay == NULL )
		r_metalShadowOverlay = ri.Cvar_Get( "r_metalShadowOverlay", "1", 0 );
	if ( !r_metalShadowOverlay->integer )
		return;

	if ( rtoLayer == nil || rtoAccelStructure == nil || !rtoHaveCamera )
		return;
	if ( !RTO_EnsureAttached() )
		return;
	if ( !RTO_EnsurePipeline() )
		return;

	id<CAMetalDrawable> drawable = [rtoLayer nextDrawable];
	if ( drawable == nil )
		return;

	struct RTOCamera {
		simd_float3 origin;
		simd_float3 forward;
		simd_float3 right;
		simd_float3 up;
		float tanHalfFovX;
		float tanHalfFovY;
		simd_float3 lightDir;
	} camera;
	camera.origin = rtoOrigin;
	camera.forward = rtoForward;
	camera.right = rtoRight;
	camera.up = rtoUp;
	camera.tanHalfFovX = rtoTanHalfFovX;
	camera.tanHalfFovY = rtoTanHalfFovY;
	// tr.sunDirection is GL2's own real sun direction (surface-to-light,
	// same convention this shadow ray needs - see tr_bsp.c's backface
	// cull against it and tr_postprocess.c's flare placement, both of
	// which place the sun/flare AT +sunDirection from the scene).
	camera.lightDir = simd_make_float3( tr.sunDirection[0], tr.sunDirection[1], tr.sunDirection[2] );

	id<MTLCommandBuffer> cmdBuf = [rtoQueue commandBuffer];
	id<MTLComputeCommandEncoder> encoder = [cmdBuf computeCommandEncoder];
	[encoder setComputePipelineState:rtoPipeline];
	[encoder setTexture:drawable.texture atIndex:0];
	[encoder setBytes:&camera length:sizeof( camera ) atIndex:0];
	[encoder setBuffer:rtoPositionBuffer offset:0 atIndex:1];
	[encoder setAccelerationStructure:rtoAccelStructure atBufferIndex:2];
	[encoder useResource:rtoPositionBuffer usage:MTLResourceUsageRead];

	MTLSize gridSize = MTLSizeMake( drawable.texture.width, drawable.texture.height, 1 );
	NSUInteger w = rtoPipeline.threadExecutionWidth;
	NSUInteger h = rtoPipeline.maxTotalThreadsPerThreadgroup / w;
	MTLSize threadgroupSize = MTLSizeMake( w, h, 1 );
	[encoder dispatchThreads:gridSize threadsPerThreadgroup:threadgroupSize];
	[encoder endEncoding];

	[cmdBuf presentDrawable:drawable];
	[cmdBuf commit];
}

extern "C" void RT_OverlayResize( int width, int height )
{
	if ( rtoLayer == nil )
		return;
	rtoLayer.drawableSize = CGSizeMake( width, height );
}

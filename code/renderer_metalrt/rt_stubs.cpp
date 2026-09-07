/*
===========================================================================
renderer_metalrt - loud stubs for every refexport_t function not yet
implemented. Each one logs exactly once (RT_STUB_ONCE, see rt_local.h)
the first time it's called, then returns a safe default - never a
silent no-op, per code/renderer_metalrt/CLAUDE.md rule 4.

As each of these gets a real implementation in a later session, move it
out of this file into its own dedicated source file (matching how the
existing renderers split tr_image.c/tr_shader.c/tr_model.cpp/etc.) and
remove its assignment below.
===========================================================================
*/
#include "rt_local.h"

// ---- Registration ----

// RegisterModel: real (placeholder-box) implementation, see
// RT_InitSceneFunctions (rt_scene.mm).

static qhandle_t RT_RegisterSkin( const char *name )
{
	RT_STUB_ONCE();
	return 0;
}

// LoadWorld: real implementation, see RT_InitWorldFunctions (rt_world.mm).

static void RT_SetWorldVisData( const byte *vis )
{
	RT_STUB_ONCE();
}

// ---- Scene submission ----

// ClearScene/AddRefEntityToScene/RenderScene: real (placeholder-box)
// implementations, see RT_InitSceneFunctions (rt_scene.mm).

static qboolean RT_AddPolyToScene( qhandle_t hShader, int numVerts, const polyVert_t *verts, int num )
{
	RT_STUB_ONCE();
	return qfalse;
}

static int RT_LightForPoint( vec3_t point, vec3_t ambientLight, vec3_t directedLight, vec3_t lightDir )
{
	RT_STUB_ONCE();
	return 0;
}

static void RT_AddLightToScene( const vec3_t org, float intensity, float r, float g, float b, int type )
{
	RT_STUB_ONCE();
}

static void RT_AddAdditiveLightToScene( const vec3_t org, float intensity, float r, float g, float b )
{
	RT_STUB_ONCE();
}

static void RT_AddRefSpriteToScene( const refEntity_t *ent )
{
	RT_STUB_ONCE();
}

static void RT_AddTerrainMarkToScene( int terrainIndex, qhandle_t hShader, int numVerts, const polyVert_t *verts, int renderfx )
{
	RT_STUB_ONCE();
}

// ---- 2D / UI ----

static void RT_SetColor( const float *rgba )
{
	RT_STUB_ONCE();
}

static void RT_DrawStretchRaw( int x, int y, int w, int h, int cols, int rows, int components, const byte *data )
{
	RT_STUB_ONCE();
}

static void RT_UploadCinematic( int w, int h, int cols, int rows, const byte *data, int client, qboolean dirty )
{
	RT_STUB_ONCE();
}

// Set2DWindow: real implementation, see RT_InitImageFunctions (rt_image.mm).

static void RT_DrawStretchPic2( float x, float y, float w, float h, float s1, float t1, float s2, float t2, float sx, float sy, qhandle_t hShader )
{
	RT_STUB_ONCE();
}

static void RT_DrawTilePic( float x, float y, float w, float h, qhandle_t hShader )
{
	RT_STUB_ONCE();
}

static void RT_DrawTilePicOffset( float x, float y, float w, float h, qhandle_t hShader, int offsetX, int offsetY )
{
	RT_STUB_ONCE();
}

static void RT_DrawTrianglePic( const vec2_t vPoints[3], const vec2_t vTexCoords[3], qhandle_t hShader )
{
	RT_STUB_ONCE();
}

static void RT_DrawBackground( int cols, int rows, int bgr, uint8_t *data )
{
	RT_STUB_ONCE();
}

static void RT_DebugLine( const vec3_t start, const vec3_t end, float r, float g, float b, float alpha )
{
	RT_STUB_ONCE();
}

static void RT_DrawBox( float x, float y, float w, float h )
{
	RT_STUB_ONCE();
}

static void RT_AddBox( float x, float y, float w, float h )
{
	RT_STUB_ONCE();
}

// Scissor: real implementation, see RT_InitImageFunctions (rt_image.mm).

static void RT_DrawLineLoop( const vec2_t *points, int count, int stippleFactor, int stippleMask )
{
	RT_STUB_ONCE();
}

static void RT_Set2DInitialShaderTime( float startTime )
{
	RT_STUB_ONCE();
}

// ---- Marks / decals ----

static int RT_MarkFragments( int numPoints, const vec3_t *points, const vec3_t projection,
	int maxPoints, vec3_t pointBuffer, int maxFragments, markFragment_t *fragmentBuffer, float fRadiusSquared )
{
	RT_STUB_ONCE();
	return 0;
}

static int RT_MarkFragmentsForInlineModel( clipHandle_t bmodel, const vec3_t vAngles, const vec3_t vOrigin, int numPoints,
	const vec3_t *points, const vec3_t projection, int maxPoints, vec3_t pointBuffer,
	int maxFragments, markFragment_t *fragmentBuffer, float fRadiusSquared )
{
	RT_STUB_ONCE();
	return 0;
}

static void RT_GetInlineModelBounds( int index, vec3_t mins, vec3_t maxs )
{
	RT_STUB_ONCE();
}

static void RT_GetLightingForDecal( vec3_t light, const vec3_t facing, const vec3_t origin )
{
	RT_STUB_ONCE();
}

static void RT_GetLightingForSmoke( vec3_t light, const vec3_t origin )
{
	RT_STUB_ONCE();
}

static int RT_GatherLightSources( const vec3_t pos, vec3_t *lightPos, vec3_t *lightIntensity, int maxLights )
{
	RT_STUB_ONCE();
	return 0;
}

// ---- Queries ----

static int RT_LerpTag( orientation_t *tag, qhandle_t model, int startFrame, int endFrame, float frac, const char *tagName )
{
	RT_STUB_ONCE();
	return 0;
}

static void RT_ModelBounds( qhandle_t model, vec3_t mins, vec3_t maxs )
{
	RT_STUB_ONCE();
}

static qboolean RT_inPVS( const vec3_t p1, const vec3_t p2 )
{
	RT_STUB_ONCE();
	// Safer default than qfalse: without real PVS data, assume visible
	// rather than incorrectly culling everything.
	return qtrue;
}

static qboolean RT_GetEntityToken( char *buffer, int size )
{
	RT_STUB_ONCE();
	return qfalse;
}

static float RT_ModelRadius( qhandle_t handle )
{
	RT_STUB_ONCE();
	return 0.0f;
}

static dtiki_t *RT_Model_GetHandle( qhandle_t handle )
{
	RT_STUB_ONCE();
	return NULL;
}

static int RT_GetShaderWidth( qhandle_t hShader )
{
	RT_STUB_ONCE();
	return 0;
}

static int RT_GetShaderHeight( qhandle_t hShader )
{
	RT_STUB_ONCE();
	return 0;
}

static const char *RT_GetShaderName( qhandle_t hShader )
{
	RT_STUB_ONCE();
	return "";
}

static const char *RT_GetModelName( qhandle_t hModel )
{
	RT_STUB_ONCE();
	return "";
}

static const char *RT_GetGraphicsInfo( void )
{
	RT_STUB_ONCE();
	return "";
}

static qboolean RT_ImageExists( const char *name )
{
	RT_STUB_ONCE();
	return qfalse;
}

static int RT_CountTextureMemory( void )
{
	RT_STUB_ONCE();
	return 0;
}

static qboolean RT_LoadRawImage( const char *name, byte **pic, int *width, int *height )
{
	RT_STUB_ONCE();
	return qfalse;
}

static void RT_FreeRawImage( byte *pic )
{
	RT_STUB_ONCE();
}

// ---- Fonts / swipe ----

static void RT_DrawString( fontheader_t *font, const char *text, float x, float y, int maxLen, const float *pvVirtualScreen )
{
	RT_STUB_ONCE();
}

static float RT_GetFontHeight( const fontheader_t *font )
{
	RT_STUB_ONCE();
	return 0.0f;
}

static float RT_GetFontStringWidth( const fontheader_t *font, const char *string )
{
	RT_STUB_ONCE();
	return 0.0f;
}

static fontheader_t *RT_LoadFont( const char *name )
{
	RT_STUB_ONCE();

	// UIFont's constructor (code/uilib/uifont.cpp) treats a NULL LoadFont
	// result as a hard Sys_Error(ERR_DROP) - the UI can't even construct
	// its default font object without one. Worse, UIFont::getCharWidth
	// and ::getHeight read the fontheader_t's internals DIRECTLY (they
	// don't go through GetFontStringWidth/GetFontHeight at all), taking
	// the "numPages == 0" branch straight to m_font->sgl[0]->indirection[ch]
	// - so a merely-non-NULL-but-otherwise-empty fontheader_t still
	// segfaults (sgl[0] is NULL) the moment any UI text measures itself,
	// which happens unavoidably during startup (View3D::InitSubtitle).
	// Hand back a font with one real (if degenerate) page: numPages left
	// at 0 so callers take that same sgl[0] branch, but sgl[0] now points
	// at a zeroed page, so every glyph resolves to a valid, zero-sized
	// location instead of dereferencing NULL - invisible text, not a
	// crash. DrawString remains a real stub; nothing here actually
	// renders a glyph. Replace this once real font loading exists.
	static fontheader_sgl_t placeholderPages[8];
	static fontheader_t placeholderFonts[8];
	static int nextPlaceholder = 0;

	int slot = nextPlaceholder % ARRAY_LEN( placeholderFonts );
	nextPlaceholder++;

	fontheader_sgl_t *page = &placeholderPages[slot];
	Com_Memset( page, 0, sizeof( *page ) );
	Q_strncpyz( page->name, name, sizeof( page->name ) );
	page->height = 16.0f;
	page->aspectRatio = 1.0f;

	fontheader_t *font = &placeholderFonts[slot];
	Com_Memset( font, 0, sizeof( *font ) );
	Q_strncpyz( font->name, name, sizeof( font->name ) );
	font->sgl[0] = page;

	return font;
}

static void RT_SwipeBegin( float thisTime, float life, qhandle_t hShader )
{
	RT_STUB_ONCE();
}

static void RT_SwipePoint( vec3_t point1, vec3_t point2, float time )
{
	RT_STUB_ONCE();
}

static void RT_SwipeEnd( void )
{
	RT_STUB_ONCE();
}

// ---- Misc / mode / TIKI ----

static void RT_RemapShader( const char *oldShader, const char *newShader, const char *offsetTime )
{
	RT_STUB_ONCE();
}

static void RT_TakeVideoFrame( int h, int w, byte *captureBuffer, byte *encodeBuffer, qboolean motionJpeg )
{
	RT_STUB_ONCE();
}

// SpawnEffectModel/RegisterServerModel: real implementations, see
// RT_InitSceneFunctions (rt_scene.mm) - they share RegisterModel's
// underlying registration logic, same as the real renderer.

static void RT_UnregisterServerModel( qhandle_t model )
{
	RT_STUB_ONCE();
}

static qhandle_t RT_RefreshShaderNoMip( const char *name )
{
	RT_STUB_ONCE();
	return 0;
}

static void RT_FreeModels( void )
{
	RT_STUB_ONCE();
}

static void RT_PrintBSPFileSizes( void )
{
	RT_STUB_ONCE();
}

static int RT_MapVersion( void )
{
	RT_STUB_ONCE();
	return 0;
}

static refEntity_t *RT_GetRenderEntity( int entityNumber )
{
	RT_STUB_ONCE();
	return NULL;
}

static void RT_SavePerformanceCounters( void )
{
	RT_STUB_ONCE();
}

static void RT_RegisterFont( const char *fontName, int pointSize, fontInfo_t *font )
{
	RT_STUB_ONCE();
}

static void RT_ForceUpdatePose( refEntity_t *model )
{
	RT_STUB_ONCE();
}

static orientation_t RT_TIKI_Orientation( refEntity_t *model, int tagNum )
{
	RT_STUB_ONCE();
	orientation_t o;
	Com_Memset( &o, 0, sizeof( o ) );
	return o;
}

static qboolean RT_TIKI_IsOnGround( refEntity_t *model, int tagNum, float threshold )
{
	RT_STUB_ONCE();
	return qfalse;
}

static void RT_SetFrameNumber( int frameNumber )
{
	RT_STUB_ONCE();
}

static void RT_SetRenderTime( int t )
{
	RT_STUB_ONCE();
}

static float RT_Noise( float x, float y, float z, double t )
{
	RT_STUB_ONCE();
	return 0.0f;
}

static qboolean RT_SetMode( int mode, const glconfig_t *glConfig )
{
	RT_STUB_ONCE();
	return qfalse;
}

static void RT_SetFullscreen( qboolean fullScreen )
{
	RT_STUB_ONCE();
}

void RT_InitStubs( refexport_t *re )
{
	// RegisterModel: real implementation, see RT_InitSceneFunctions
	// (rt_scene.mm), called separately below.
	re->RegisterSkin = RT_RegisterSkin;
	// RegisterShader/RegisterShaderNoMip: real implementations, see
	// RT_InitImageFunctions (rt_image.mm), called separately below.
	// LoadWorld: real implementation, see RT_InitWorldFunctions
	// (rt_world.mm), called separately below.
	re->SetWorldVisData = RT_SetWorldVisData;

	// ClearScene/AddRefEntityToScene/RenderScene: real implementations,
	// see RT_InitSceneFunctions.
	re->AddPolyToScene = RT_AddPolyToScene;
	re->LightForPoint = RT_LightForPoint;
	re->AddLightToScene = RT_AddLightToScene;
	re->AddAdditiveLightToScene = RT_AddAdditiveLightToScene;
	re->AddRefSpriteToScene = RT_AddRefSpriteToScene;
	re->AddTerrainMarkToScene = RT_AddTerrainMarkToScene;

	re->SetColor = RT_SetColor;
	re->DrawStretchRaw = RT_DrawStretchRaw;
	re->UploadCinematic = RT_UploadCinematic;
	// Set2DWindow/DrawStretchPic/Scissor: real implementations, see
	// RT_InitImageFunctions.
	re->DrawStretchPic2 = RT_DrawStretchPic2;
	re->DrawTilePic = RT_DrawTilePic;
	re->DrawTilePicOffset = RT_DrawTilePicOffset;
	re->DrawTrianglePic = RT_DrawTrianglePic;
	re->DrawBackground = RT_DrawBackground;
	re->DebugLine = RT_DebugLine;
	re->DrawBox = RT_DrawBox;
	re->AddBox = RT_AddBox;
	re->DrawLineLoop = RT_DrawLineLoop;
	re->Set2DInitialShaderTime = RT_Set2DInitialShaderTime;

	re->MarkFragments = RT_MarkFragments;
	re->MarkFragmentsForInlineModel = RT_MarkFragmentsForInlineModel;
	re->GetInlineModelBounds = RT_GetInlineModelBounds;
	re->GetLightingForDecal = RT_GetLightingForDecal;
	re->GetLightingForSmoke = RT_GetLightingForSmoke;
	re->R_GatherLightSources = RT_GatherLightSources;

	re->LerpTag = RT_LerpTag;
	re->ModelBounds = RT_ModelBounds;
	re->inPVS = RT_inPVS;
	re->GetEntityToken = RT_GetEntityToken;
	re->ModelRadius = RT_ModelRadius;
	re->R_Model_GetHandle = RT_Model_GetHandle;
	re->GetShaderWidth = RT_GetShaderWidth;
	re->GetShaderHeight = RT_GetShaderHeight;
	re->GetShaderName = RT_GetShaderName;
	re->GetModelName = RT_GetModelName;
	re->GetGraphicsInfo = RT_GetGraphicsInfo;
	re->ImageExists = RT_ImageExists;
	re->CountTextureMemory = RT_CountTextureMemory;
	re->LoadRawImage = RT_LoadRawImage;
	re->FreeRawImage = RT_FreeRawImage;

	re->DrawString = RT_DrawString;
	re->GetFontHeight = RT_GetFontHeight;
	re->GetFontStringWidth = RT_GetFontStringWidth;
	re->LoadFont = RT_LoadFont;
	re->SwipeBegin = RT_SwipeBegin;
	re->SwipePoint = RT_SwipePoint;
	re->SwipeEnd = RT_SwipeEnd;

	re->RemapShader = RT_RemapShader;
	re->TakeVideoFrame = RT_TakeVideoFrame;
	// SpawnEffectModel/RegisterServerModel: real implementations, see
	// RT_InitSceneFunctions.
	re->UnregisterServerModel = RT_UnregisterServerModel;
	re->RefreshShaderNoMip = RT_RefreshShaderNoMip;
	re->FreeModels = RT_FreeModels;
	re->PrintBSPFileSizes = RT_PrintBSPFileSizes;
	re->MapVersion = RT_MapVersion;
	re->GetRenderEntity = RT_GetRenderEntity;
	re->SavePerformanceCounters = RT_SavePerformanceCounters;
	re->RegisterFont = RT_RegisterFont;
	re->ForceUpdatePose = RT_ForceUpdatePose;
	re->TIKI_Orientation = RT_TIKI_Orientation;
	re->TIKI_IsOnGround = RT_TIKI_IsOnGround;
	re->SetFrameNumber = RT_SetFrameNumber;
	re->SetRenderTime = RT_SetRenderTime;
	re->Noise = RT_Noise;
	re->SetMode = RT_SetMode;
	re->SetFullscreen = RT_SetFullscreen;
}

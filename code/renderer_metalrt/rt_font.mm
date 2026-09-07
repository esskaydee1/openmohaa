/*
===========================================================================
renderer_metalrt - Phase 1 session 12: real font loading and text
rendering (LoadFont, DrawString, GetFontHeight, GetFontStringWidth).

MOHAA's simple (non-multi-page) fonts are plain-text ".RitualFont"
files (fonts/<name>.RitualFont) parsed with the same COM_Parse
tokenizer already used for .shader scripts (session 8): a height, an
aspectRatio, a 256-entry `indirection` table mapping a character code
to a glyph slot (-1 = no glyph), and a 256-entry `locations` table of
normalized UV rects (pos/size, already divided by 256 at load time)
into one shared glyph-atlas texture named "gfx/fonts/<name>" - resolved
through the same RT_RegisterImageCommon/.shader pipeline any other
image name goes through. See code/renderergl2/tr_font.cpp's
R_LoadFont_sgl/R_DrawString_sgl/R_GetFontStringWidth_sgl for the real,
byte-for-byte reference this ports.

Deliberately scoped to only the common case: fontheader_t::numPages==0
(a single sgl page - matches the real renderer's own dispatch, see
R_DrawString's "if (!font->numPages)" branch). Multi-page fonts (CJK/
unicode, using the charTable indirection) are rarer, real, separate
work - RT_LoadFont still hands back a safe, glyph-empty font for those
rather than crashing (same reasoning as the original crash-fix stub).
===========================================================================
*/
#include "rt_local.h"

#include <stdlib.h>

// rt_image.mm (not anonymous-namespace-scoped there) - reused to
// resolve a font's glyph-atlas texture the same way any other image
// name resolves, and to draw each glyph's quad exactly the way
// DrawStretchPic draws any other textured 2D quad (same pipeline, same
// Set2DWindow-based local-to-screen mapping).
qhandle_t RT_RegisterImageCommon( const char *name );
void RT_DrawStretchPic( float x, float y, float w, float h,
	float s1, float t1, float s2, float t2, qhandle_t hShader );

namespace {

#define MAX_RT_FONTS 32

struct rtFont_t {
	fontheader_sgl_t sgl;
	fontheader_t header;
};

rtFont_t rtFonts[MAX_RT_FONTS];
int numRtFonts = 0;

// UIFont's constructor (code/uilib/uifont.cpp) hard-Sys_Errors on a
// NULL LoadFont result, and UIFont::getCharWidth/getHeight read a
// fontheader_t's internals directly (bypassing GetFontStringWidth/
// GetFontHeight), taking the numPages==0 branch straight to
// sgl[0]->indirection[ch] - so even a real parse failure must still
// hand back a non-NULL font with a real (if glyph-empty) sgl[0] page,
// never NULL. Every indirection stays -1 (memset default, matching
// "no glyph" - see below), so every character silently draws nothing
// rather than crashing or drawing garbage.
//
// Deliberately its OWN small ring buffer, separate from rtFonts[]/
// numRtFonts - a caller that already holds a pointer to a REAL,
// successfully-parsed font (UIFont caches this permanently) must never
// have that storage silently overwritten by an unrelated later parse
// failure; keeping fallbacks in a disjoint array makes that impossible
// rather than merely unlikely.
rtFont_t rtFallbackFonts[8];
int nextRtFallbackFont = 0;

fontheader_t *RT_LoadFontFallback( const char *name )
{
	rtFont_t *slot = &rtFallbackFonts[nextRtFallbackFont];
	nextRtFallbackFont = ( nextRtFallbackFont + 1 ) % ARRAY_LEN( rtFallbackFonts );

	Com_Memset( slot, 0, sizeof( *slot ) );
	for ( int i = 0; i < 256; i++ )
		slot->sgl.indirection[i] = -1;

	Q_strncpyz( slot->sgl.name, name, sizeof( slot->sgl.name ) );
	slot->sgl.height = 16.0f;
	slot->sgl.aspectRatio = 1.0f;
	slot->sgl.trhandle = 0; // 0 = invalid qhandle_t - RT_DrawString treats this as "nothing to draw"

	Q_strncpyz( slot->header.name, name, sizeof( slot->header.name ) );
	slot->header.sgl[0] = &slot->sgl;

	return &slot->header;
}

} // namespace

static fontheader_t *RT_LoadFont( const char *name )
{
	for ( int i = 0; i < numRtFonts; i++ )
	{
		if ( !Q_stricmp( rtFonts[i].header.name, name ) )
			return &rtFonts[i].header;
	}

	if ( numRtFonts >= MAX_RT_FONTS )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: LoadFont: MAX_RT_FONTS (%d) hit, dropping \"%s\"\n",
			MAX_RT_FONTS, name );
		return RT_LoadFontFallback( name );
	}

	char path[MAX_QPATH];
	Com_sprintf( path, sizeof( path ), "fonts/%s.RitualFont", name );

	byte *fileData = NULL;
	long fileLen = ri.FS_ReadFile( path, (void **)&fileData );
	if ( fileLen < 0 || fileData == NULL )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: LoadFont: couldn't find \"%s\"\n", path );
		return RT_LoadFontFallback( name );
	}

	rtFont_t *slot = &rtFonts[numRtFonts];
	Com_Memset( slot, 0, sizeof( *slot ) );
	for ( int i = 0; i < 256; i++ )
		slot->sgl.indirection[i] = -1;
	Q_strncpyz( slot->sgl.name, name, sizeof( slot->sgl.name ) );

	char *p = (char *)fileData;
	bool error = false;
	const char *token;
	while ( true )
	{
		token = COM_Parse( &p );
		if ( !token[0] )
			break;

		if ( !Q_stricmp( token, "RitFont" ) )
			continue;

		if ( !Q_stricmp( token, "indirections" ) )
		{
			token = COM_Parse( &p );
			if ( Q_stricmp( token, "{" ) ) { error = true; break; }

			for ( int i = 0; i < 256; i++ )
			{
				token = COM_Parse( &p );
				if ( !token[0] ) { error = true; break; }
				slot->sgl.indirection[i] = atoi( token );
			}
			if ( error )
				break;

			token = COM_Parse( &p );
			if ( Q_stricmp( token, "}" ) ) { error = true; break; }
		}
		else if ( !Q_stricmp( token, "locations" ) )
		{
			token = COM_Parse( &p );
			if ( Q_stricmp( token, "{" ) ) { error = true; break; }

			for ( int i = 0; i < 256; i++ )
			{
				token = COM_Parse( &p );
				if ( Q_stricmp( token, "{" ) ) { error = true; break; }

				if ( slot->sgl.aspectRatio == 0.0f )
				{
					ri.Printf( PRINT_WARNING, "renderer_metalrt: LoadFont: \"aspect\" must come before "
						"\"locations\" in \"%s\"\n", path );
					error = true;
					break;
				}

				slot->sgl.locations[i].pos[0] = (float)atof( COM_Parse( &p ) ) / 256.0f;
				slot->sgl.locations[i].pos[1] = (float)atof( COM_Parse( &p ) ) * slot->sgl.aspectRatio / 256.0f;
				slot->sgl.locations[i].size[0] = (float)atof( COM_Parse( &p ) ) / 256.0f;
				slot->sgl.locations[i].size[1] = (float)atof( COM_Parse( &p ) ) * slot->sgl.aspectRatio / 256.0f;

				token = COM_Parse( &p );
				if ( Q_stricmp( token, "}" ) ) { error = true; break; }
			}
			if ( error )
				break;

			token = COM_Parse( &p );
			if ( Q_stricmp( token, "}" ) ) { error = true; break; }
		}
		else if ( !Q_stricmp( token, "height" ) )
		{
			slot->sgl.height = (float)atof( COM_Parse( &p ) );
		}
		else if ( !Q_stricmp( token, "aspect" ) )
		{
			slot->sgl.aspectRatio = (float)atof( COM_Parse( &p ) );
		}
		else
		{
			// Unknown token - matches the real loader's tolerant stop
			// rather than a hard failure (some .RitualFont files may
			// carry extra trailing sections this parser doesn't need).
			break;
		}
	}

	ri.FS_FreeFile( fileData );

	if ( error || slot->sgl.height <= 0.0f || slot->sgl.aspectRatio <= 0.0f )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: LoadFont: failed to parse \"%s\"\n", path );
		return RT_LoadFontFallback( name );
	}

	char shaderPath[MAX_QPATH];
	Com_sprintf( shaderPath, sizeof( shaderPath ), "gfx/fonts/%s", name );
	slot->sgl.trhandle = RT_RegisterImageCommon( shaderPath );
	if ( slot->sgl.trhandle == 0 )
	{
		ri.Printf( PRINT_WARNING, "renderer_metalrt: LoadFont: couldn't load glyph atlas \"%s\"\n", shaderPath );
		return RT_LoadFontFallback( name );
	}

	Q_strncpyz( slot->header.name, name, sizeof( slot->header.name ) );
	slot->header.sgl[0] = &slot->sgl;
	numRtFonts++;

	ri.Printf( PRINT_DEVELOPER, "renderer_metalrt: registered font \"%s\" (height %.1f, aspect %.2f)\n",
		name, slot->sgl.height, slot->sgl.aspectRatio );

	return &slot->header;
}

// Session 8's shader-script indirection means a font's glyph atlas
// resolves through the exact same RT_RegisterImageCommon call any other
// image name does - fontheader_sgl_t::trhandle (an int the real
// renderer uses for a different purpose, an internal cache-invalidation
// sequence number) is repurposed here to simply hold the resolved
// qhandle_t, since this renderer has no equivalent caching to do.
static void RT_DrawString( fontheader_t *font, const char *text, float x, float y, int maxLen, const float *pvVirtualScreen )
{
	if ( font == NULL || font->sgl[0] == NULL || text == NULL )
		return;

	fontheader_sgl_t *sgl = font->sgl[0];
	qhandle_t hShader = (qhandle_t)sgl->trhandle;
	if ( hShader == 0 )
		return; // fallback/degenerate font (see RT_LoadFontFallback) - nothing to draw

	float widthScale = 1.0f, heightScale = 1.0f;
	bool useVirtualScreen = ( pvVirtualScreen != NULL );
	if ( useVirtualScreen )
	{
		widthScale = ( pvVirtualScreen[0] != 0.0f ) ? pvVirtualScreen[0] : ( (float)rtGlConfig.vidWidth / 640.0f );
		heightScale = ( pvVirtualScreen[1] != 0.0f ) ? pvVirtualScreen[1] : ( (float)rtGlConfig.vidHeight / 480.0f );
	}

	float startX = x;
	float curX = x;
	float curY = y;
	float charHeight = sgl->height;

	for ( int i = 0; text[i] != '\0' && ( maxLen < 0 || i < maxLen ); i++ )
	{
		unsigned char c = (unsigned char)text[i];

		if ( c == '\n' )
		{
			curY += charHeight;
			curX = startX;
			continue;
		}
		if ( c == '\r' )
		{
			curX = startX;
			continue;
		}

		int indirected = ( c == '\t' ) ? sgl->indirection[32] : sgl->indirection[c];
		if ( indirected < 0 )
		{
			if ( c == '\t' )
				continue; // no space glyph to advance by - nothing sane to do
			indirected = sgl->indirection['?'];
			if ( indirected < 0 )
				continue; // no fallback glyph either - skip this character
		}

		letterloc_t *loc = &sgl->locations[indirected];
		float glyphWidth = loc->size[0] * 256.0f;

		if ( c == '\t' )
		{
			curX += glyphWidth * 3.0f;
			continue;
		}

		float drawX = curX, drawY = curY, drawW = glyphWidth, drawH = charHeight;
		if ( useVirtualScreen )
		{
			drawX *= widthScale;
			drawY *= heightScale;
			drawW *= widthScale;
			drawH *= heightScale;
		}

		RT_DrawStretchPic( drawX, drawY, drawW, drawH,
			loc->pos[0], loc->pos[1], loc->pos[0] + loc->size[0], loc->pos[1] + loc->size[1], hShader );

		curX += glyphWidth;
	}
}

static float RT_GetFontHeight( const fontheader_t *font )
{
	if ( font == NULL || font->sgl[0] == NULL )
		return 0.0f;
	return font->sgl[0]->height;
}

static float RT_GetFontStringWidth( const fontheader_t *font, const char *string )
{
	if ( font == NULL || font->sgl[0] == NULL || string == NULL )
		return 0.0f;

	const fontheader_sgl_t *sgl = font->sgl[0];
	float width = 0.0f;

	for ( int i = 0; string[i] != '\0'; i++ )
	{
		unsigned char c = (unsigned char)string[i];
		int indirected = ( c == '\t' ) ? sgl->indirection[32] : sgl->indirection[c];
		if ( indirected < 0 )
			continue;

		float glyphWidth = sgl->locations[indirected].size[0];
		width += ( c == '\t' ) ? glyphWidth * 3.0f : glyphWidth;
	}

	return width * 256.0f;
}

void RT_InitFontFunctions( refexport_t *re )
{
	re->LoadFont = RT_LoadFont;
	re->DrawString = RT_DrawString;
	re->GetFontHeight = RT_GetFontHeight;
	re->GetFontStringWidth = RT_GetFontStringWidth;
}

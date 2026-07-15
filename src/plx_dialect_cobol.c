/*
 * plx_dialect_cobol.c - the "plxcobol" dialect (ISO/IEC 1989:2023, COBOL 2023).
 *
 * COBOL is verb-driven and free-format (COBOL 2023). Unlike the other dialects
 * it does not fit the shared byte lexer's expression model (hyphenated words,
 * period sentence terminators, PICTURE clauses), so the COBOL front end in
 * plx_transpile.c uses its own tokenizer and recursive-descent parser and emits
 * plpgsql directly. This surface is mostly a marker (block_style COBOL); the
 * keyword table is unused by the COBOL path but kept for consistency.
 */
#include "postgres.h"

#include "fmgr.h"
#include "utils/memutils.h"

#include "plx.h"
#include "plx_int.h"

PG_FUNCTION_INFO_V1(plx_cob_validator);
PG_FUNCTION_INFO_V1(plx_cob_inline_handler);

static const PlxSurface cob_surface = {
	.lanname = "plxcobol",
	.block_style = PLX_BLK_COBOL,
	.stmt_semicolon = false,
	.var_sigil = 0,
	.cmt_hash = false,
	.cmt_slash = false,
	.cmt_block = false,
	.type_ann = NULL,
	.interp_quote = 0,
	.interp_hashbrace = false,
	.interp_dollar = false,
	.interp_dollarbrace = false,
	.fstrings = false,
	.concat_op = 0,
	.kws = NULL,
	.nkws = 0,
	.excs = NULL,
	.nexcs = 0,
	.flags = PLX_TRUSTED,
};

static char *
cob_transpile(const char *src, const PlxFuncMeta *meta)
{
	return plx_transpile(src, meta, &cob_surface, CurrentMemoryContext);
}

const PlxDialect plx_cobol_dialect = {
	.abi_version = PLX_ABI_VERSION,
	.lanname = "plxcobol",
	.transpile = cob_transpile,
	.flags = PLX_TRUSTED,
};

Datum
plx_cob_validator(PG_FUNCTION_ARGS)
{
	return plx_generic_validator(fcinfo, &plx_cobol_dialect);
}

Datum
plx_cob_inline_handler(PG_FUNCTION_ARGS)
{
	return plx_generic_inline_handler(fcinfo, &plx_cobol_dialect);
}

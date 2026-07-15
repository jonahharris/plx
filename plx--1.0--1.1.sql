/* plx 1.0 -> 1.1: add the plxcobol dialect (ISO/IEC 1989:2023) */

/* COBOL dialect (ISO/IEC 1989:2023) validator + inline handler live in plx.so */
CREATE FUNCTION plx_cob_validator(oid)
	RETURNS void
	AS '$libdir/plx', 'plx_cob_validator'
	LANGUAGE C STRICT;

CREATE FUNCTION plx_cob_inline_handler(internal)
	RETURNS void
	AS '$libdir/plx', 'plx_cob_inline_handler'
	LANGUAGE C;

CREATE TRUSTED LANGUAGE plxcobol
	HANDLER plx_call_handler
	INLINE plx_cob_inline_handler
	VALIDATOR plx_cob_validator;

COMMENT ON LANGUAGE plxcobol IS 'plx COBOL dialect (ISO/IEC 1989:2023, transpiles to plpgsql)';

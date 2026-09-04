/*-------------------------------------------------------------------------
 *
 * lance_option.h
 *	  The SQL option surface of lance_fdw (DESIGN section 2).
 *
 * IDENTIFICATION
 *	  src/lance_option.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef LANCE_OPTION_H
#define LANCE_OPTION_H

#include "access/attnum.h"
#include "nodes/pg_list.h"

typedef struct LanceTableOptions
{
	Oid			serverid;		/* server the table belongs to */
	char	   *raw_uri;		/* uri option exactly as written */
	char	   *uri;			/* resolved against the server's base_uri */
	uint64		version;		/* dataset version, 0 = latest */
	int64		batch_size;		/* 0 = leave lance-c at its default */
	double		rows_hint;		/* 0 = use LANCE_FDW_DEFAULT_ROWS */
} LanceTableOptions;

/* Validator body; `catalog` is the pg_* relation the options belong to. */
extern void lance_validate_options(List *options_list, Oid catalog);

/* Server option base_uri, or NULL if the server does not set one. */
extern char *lance_server_base_uri(Oid serverid);

/*
 * Turn a dataset name into a uri.  Absolute names (a scheme, or a leading
 * slash) are taken as they are; everything else needs base_uri.
 */
extern char *lance_resolve_uri(const char *base_uri, const char *name);

extern void lance_get_table_options(Oid foreigntableid,
									LanceTableOptions *opts);

/*
 * The Lance column name behind one attribute: the column_name option when the
 * table sets one, the attribute name otherwise.
 */
extern char *lance_get_column_name(Oid foreigntableid, AttrNumber attnum,
								   const char *attname);

/*
 * Object-store options for lance_dataset_open(), as the NULL-terminated
 * key/value array lance-c expects.  Credentials are read here, straight from
 * the user mapping, and never travel through a plan (DESIGN D5, I4).
 */
extern const char **lance_build_storage_options(Oid serverid, Oid userid);

#endif							/* LANCE_OPTION_H */

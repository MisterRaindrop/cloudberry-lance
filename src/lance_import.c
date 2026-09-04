/*-------------------------------------------------------------------------
 *
 * lance_import.c
 *	  IMPORT FOREIGN SCHEMA for lance_fdw (DESIGN D15).
 *
 * LIMIT TO is mandatory: lance-c has no API that enumerates the datasets under
 * a prefix, and inventing one out of an S3 listing would be a second
 * dependency surface.  Saying so out loud is more honest than pretending the
 * wrapper has a catalog.
 *
 * B-tier columns are skipped with a NOTICE naming the column and its Arrow
 * type (I8), and a dataset with nothing left to import is an error rather than
 * an empty table.
 *
 * IDENTIFICATION
 *	  src/lance_import.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "lance_fdw.h"
#include "lance_arrow.h"
#include "lance_import.h"
#include "lance_option.h"
#include "lance_runtime.h"

#include "foreign/foreign.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "utils/builtins.h"

static void
lance_import_columns(StringInfo buf, ImportForeignSchemaStmt *stmt,
					 ForeignServer *server, const char *name,
					 struct ArrowSchema *schema)
{
	int			ncols = 0;
	int			nskipped = 0;
	int64		i;

	appendStringInfo(buf, "CREATE FOREIGN TABLE %s.%s (\n",
					 quote_identifier(stmt->local_schema),
					 quote_identifier(name));

	for (i = 0; i < schema->n_children; i++)
	{
		struct ArrowSchema *field = schema->children[i];
		const char *colname;
		Oid			typid;
		int32		typmod;
		bool		is_b_tier;

		if (field == NULL || field->name == NULL || field->name[0] == '\0')
			ereport(ERROR,
					(errcode(ERRCODE_FDW_INVALID_COLUMN_NAME),
					 errmsg("lance_fdw: field %d of dataset \"%s\" has no name",
							(int) i, name)));

		colname = field->name;

		if (!lance_arrow_map_type(field, &typid, &typmod, &is_b_tier))
		{
			if (lance_arrow_is_blob_encoded(field))
				ereport(NOTICE,
						(errmsg("skipping column \"%s\" of \"%s\": Lance blob encoding is not supported",
								colname, name)));
			else
			{
				const char *typname = lance_arrow_type_name(field);

				ereport(NOTICE,
						(errmsg("skipping column \"%s\" of \"%s\": Arrow type \"%s\" (%s) is not supported",
								colname, name, lance_arrow_format(field),
								typname != NULL ? typname : "unparsable")));
			}
			nskipped++;
			continue;
		}

		if (ncols > 0)
			appendStringInfoString(buf, ",\n");

		appendStringInfo(buf, "  %s %s",
						 quote_identifier(colname),
						 format_type_with_typemod(typid, typmod));

		/*
		 * A name PostgreSQL would truncate has to be pinned down with a
		 * column_name option, or the scan would look for the truncated name.
		 */
		if (strlen(colname) >= NAMEDATALEN)
			appendStringInfo(buf, " OPTIONS (column_name %s)",
							 quote_literal_cstr(colname));

		ncols++;
	}

	if (ncols == 0)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("dataset \"%s\" has no column lance_fdw can read", name),
				 errdetail("All %d columns have unsupported types.", nskipped)));

	appendStringInfo(buf, "\n) SERVER %s\n  OPTIONS (uri %s)",
					 quote_identifier(server->servername),
					 quote_literal_cstr(name));
}

/*
 * Open one dataset and turn its schema into a CREATE FOREIGN TABLE statement.
 * The dataset handle and the exported ArrowSchema are both released on the
 * error path as well as the normal one (I6).
 */
static char *
lance_import_one(ImportForeignSchemaStmt *stmt, ForeignServer *server,
				 const char *base_uri, const char **storage_opts,
				 const char *name)
{
	char	   *uri = lance_resolve_uri(base_uri, name);
	LanceDataset *dataset;
	LanceHandle *handle;
	LanceSession *session;
	struct ArrowSchema schema;
	StringInfoData buf;
	int32		rc;

	/* Brings the runtime up, and may ereport: outside the masked call. */
	session = lance_rt_session();

	LANCE_MASKED(dataset = lance_dataset_open_with_session(uri,
														   (const char *const *) storage_opts,
														   0,
														   session));
	LANCE_CHECK(dataset != NULL, uri);
	handle = lance_rt_track_dataset(dataset);

	memset(&schema, 0, sizeof(schema));
	LANCE_MASKED(rc = lance_dataset_schema(dataset, &schema));
	LANCE_CHECK(rc == 0, uri);

	initStringInfo(&buf);

	PG_TRY();
	{
		lance_import_columns(&buf, stmt, server, name, &schema);
	}
	PG_FINALLY();
	{
		if (schema.release != NULL)
			LANCE_MASKED(schema.release(&schema));
	}
	PG_END_TRY();

	lance_rt_release(handle);

	return buf.data;
}

List *
lanceImportForeignSchema(ImportForeignSchemaStmt *stmt, Oid serverOid)
{
	ForeignServer *server;
	char	   *base_uri;
	const char **storage_opts;
	List	   *commands = NIL;
	ListCell   *lc;

	if (stmt->list_type != FDW_IMPORT_SCHEMA_LIMIT_TO)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("IMPORT FOREIGN SCHEMA for lance_fdw requires LIMIT TO"),
				 errdetail("Lance has no catalog that lists the datasets under a uri."),
				 errhint("Name the datasets, for example LIMIT TO (\"sales.lance\").")));

	server = GetForeignServer(serverOid);
	base_uri = lance_server_base_uri(serverOid);
	storage_opts = lance_build_storage_options(serverOid, GetUserId());

	lance_rt_init();

	foreach(lc, stmt->table_list)
	{
		RangeVar   *rv = (RangeVar *) lfirst(lc);

		commands = lappend(commands,
						   lance_import_one(stmt, server, base_uri,
											storage_opts, rv->relname));
	}

	return commands;
}

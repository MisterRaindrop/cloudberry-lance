/*-------------------------------------------------------------------------
 *
 * lance_import.h
 *	  IMPORT FOREIGN SCHEMA for lance_fdw (DESIGN D15).
 *
 * IDENTIFICATION
 *	  src/lance_import.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef LANCE_IMPORT_H
#define LANCE_IMPORT_H

#include "nodes/parsenodes.h"

extern List *lanceImportForeignSchema(ImportForeignSchemaStmt *stmt,
									  Oid serverOid);

#endif							/* LANCE_IMPORT_H */

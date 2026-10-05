/*-------------------------------------------------------------------------
 *
 * lance_deparse.h
 *	  Turning a PostgreSQL qual into a Lance SQL filter, or refusing to.
 *
 * Two passes over the same expression tree, both inside one call from
 * GetForeignPlan (DESIGN D1): the first decides whether every node is on the
 * whitelist, the second renders.  Either pass may say no, and "no" is an
 * ordinary answer - the clause simply stays with the ForeignScan.  Splitting
 * the two across planner stages would mean the render could no longer refuse,
 * because by then the clause has already been taken out of scan_clauses.
 *
 * IDENTIFICATION
 *	  src/lance_deparse.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef LANCE_DEPARSE_H
#define LANCE_DEPARSE_H

#include "lance_fdw.h"

#include "nodes/pathnodes.h"
#include "nodes/primnodes.h"

/*
 * What one successful deparse produced.
 *
 * `attnums` is every column the filter refers to.  They travel to the QE
 * separately from the projection, because the whole point of pushing a
 * qualifier down is that its columns no longer have to be read - but they
 * still have to be checked against the dataset schema (DESIGN D4).
 */
typedef struct LanceDeparsed
{
	char	   *sql;			/* the rendered filter */
	List	   *attnums;		/* List of Integer: columns it refers to */
} LanceDeparsed;

/*
 * Try to render one qual.  Returns true and fills *out on success; returns
 * false, having written nothing, when the clause is not on the whitelist or
 * cannot be rendered exactly.  Never raises.
 */
extern bool lance_deparse_qual(Expr *expr, Oid foreigntableid,
							   Index varno, LanceDeparsed *out);

/*
 * Quote a Lance column name for the filter dialect.  Returns NULL when the
 * name cannot be expressed - which today means it contains a backtick, the
 * one character the dialect gives no way to escape (PROBE-1 Q1).
 */
extern char *lance_deparse_quote_ident(const char *name);

#endif							/* LANCE_DEPARSE_H */

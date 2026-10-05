/*-------------------------------------------------------------------------
 *
 * lance_fdw.c
 *	  Handler and validator for the lance_fdw foreign-data wrapper.
 *
 * This change carries the DDL surface: the extension installs, servers, user
 * mappings and foreign tables validate their options, and IMPORT FOREIGN
 * SCHEMA turns a Lance dataset schema into a foreign table.  The scan
 * callbacks are registered but only far enough to plan; BeginForeignScan says
 * so instead of returning wrong rows.  The MPP scan replaces them in the next
 * change.
 *
 * IDENTIFICATION
 *	  src/lance_fdw.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "fmgr.h"

#include "lance_fdw.h"
#include "lance_import.h"
#include "lance_option.h"
#include "lance_runtime.h"

#include "access/reloptions.h"
#include "foreign/fdwapi.h"
#include "foreign/foreign.h"
#include "optimizer/pathnode.h"
#include "optimizer/planmain.h"
#include "optimizer/restrictinfo.h"

PG_MODULE_MAGIC;

void		_PG_init(void);

PG_FUNCTION_INFO_V1(lance_fdw_handler);
PG_FUNCTION_INFO_V1(lance_fdw_validator);

static void lanceGetForeignRelSize(PlannerInfo *root, RelOptInfo *baserel,
								   Oid foreigntableid);
static void lanceGetForeignPaths(PlannerInfo *root, RelOptInfo *baserel,
								 Oid foreigntableid);
static ForeignScan *lanceGetForeignPlan(PlannerInfo *root, RelOptInfo *baserel,
										Oid foreigntableid,
										ForeignPath *best_path,
										List *tlist,
										List *scan_clauses,
										Plan *outer_plan);
static void lanceBeginForeignScan(ForeignScanState *node, int eflags);
static TupleTableSlot *lanceIterateForeignScan(ForeignScanState *node);
static void lanceReScanForeignScan(ForeignScanState *node);
static void lanceEndForeignScan(ForeignScanState *node);

void
_PG_init(void)
{
	lance_rt_define_gucs();
	lance_rt_register_callback();
}

Datum
lance_fdw_handler(PG_FUNCTION_ARGS)
{
	FdwRoutine *routine = makeNode(FdwRoutine);

	routine->GetForeignRelSize = lanceGetForeignRelSize;
	routine->GetForeignPaths = lanceGetForeignPaths;
	routine->GetForeignPlan = lanceGetForeignPlan;
	routine->BeginForeignScan = lanceBeginForeignScan;
	routine->IterateForeignScan = lanceIterateForeignScan;
	routine->ReScanForeignScan = lanceReScanForeignScan;
	routine->EndForeignScan = lanceEndForeignScan;

	routine->ImportForeignSchema = lanceImportForeignSchema;

	PG_RETURN_POINTER(routine);
}

Datum
lance_fdw_validator(PG_FUNCTION_ARGS)
{
	List	   *options_list = untransformRelOptions(PG_GETARG_DATUM(0));
	Oid			catalog = PG_GETARG_OID(1);

	lance_validate_options(options_list, catalog);

	PG_RETURN_VOID();
}

/*
 * Planning does no I/O (I13), so the row count is the rows_hint option or a
 * constant.  Nothing here reaches the object store, which is what keeps
 * EXPLAIN working against a server whose credentials are wrong.
 */
static void
lanceGetForeignRelSize(PlannerInfo *root, RelOptInfo *baserel,
					   Oid foreigntableid)
{
	LanceTableOptions *opts;

	opts = (LanceTableOptions *) palloc0(sizeof(LanceTableOptions));
	lance_get_table_options(foreigntableid, opts);

	baserel->fdw_private = (void *) opts;
	baserel->rows = opts->rows_hint > 0.0 ? opts->rows_hint
		: LANCE_FDW_DEFAULT_ROWS;
}

/*
 * One path.  There is no filter or ordering pushdown in this block, so there
 * is nothing to choose between; the locus that makes the scan run on every
 * segment comes from mpp_execute and is added by create_foreignscan_path().
 */
static void
lanceGetForeignPaths(PlannerInfo *root, RelOptInfo *baserel,
					 Oid foreigntableid)
{
	Cost		startup_cost = 10.0;
	Cost		total_cost = startup_cost + baserel->rows * 0.01;

	add_path(baserel, (Path *)
			 create_foreignscan_path(root,
									 baserel,
									 NULL,	/* default pathtarget */
									 baserel->rows,
									 startup_cost,
									 total_cost,
									 NIL,	/* no pathkeys */
									 NULL,	/* no outer rel */
									 NULL,	/* no extra plan */
									 NIL),
			 root);
}

static ForeignScan *
lanceGetForeignPlan(PlannerInfo *root, RelOptInfo *baserel,
					Oid foreigntableid, ForeignPath *best_path,
					List *tlist, List *scan_clauses, Plan *outer_plan)
{
	List	   *fdw_private;

	/* No filter pushdown yet: every clause stays with the ForeignScan. */
	scan_clauses = extract_actual_clauses(scan_clauses, false);

	/*
	 * DESIGN D2 reserves slot 0 for retrieved_attrs and slot 1 for the Lance
	 * column names; the QD appends the scan units at slot 2 in
	 * BeginForeignScan.  Both are filled in once the scan exists.
	 */
	fdw_private = list_make2(NIL, NIL);

	return make_foreignscan(tlist,
							scan_clauses,
							baserel->relid,
							NIL,	/* no expressions to evaluate */
							fdw_private,
							NIL,	/* no custom tlist */
							NIL,	/* no recheck quals */
							outer_plan);
}

static void
lanceBeginForeignScan(ForeignScanState *node, int eflags)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("lance_fdw: scan is not implemented in this build"),
			 errdetail("This build provides the DDL and IMPORT FOREIGN SCHEMA surface only.")));
}

static TupleTableSlot *
lanceIterateForeignScan(ForeignScanState *node)
{
	/* Unreachable: BeginForeignScan never lets a scan start. */
	return NULL;
}

static void
lanceReScanForeignScan(ForeignScanState *node)
{
}

static void
lanceEndForeignScan(ForeignScanState *node)
{
}

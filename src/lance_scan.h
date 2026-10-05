/*-------------------------------------------------------------------------
 *
 * lance_scan.h
 *	  The executor side of lance_fdw: everything between BeginForeignScan and
 *	  EndForeignScan.
 *
 * IDENTIFICATION
 *	  src/lance_scan.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef LANCE_SCAN_H
#define LANCE_SCAN_H

#include "lance_fdw.h"

#include "commands/explain.h"
#include "nodes/execnodes.h"

extern void lance_scan_begin(ForeignScanState *node, int eflags);
extern TupleTableSlot *lance_scan_next(ForeignScanState *node);
extern void lance_scan_rescan(ForeignScanState *node);
extern void lance_scan_end(ForeignScanState *node);
extern void lance_scan_explain(ForeignScanState *node, ExplainState *es);

#endif							/* LANCE_SCAN_H */

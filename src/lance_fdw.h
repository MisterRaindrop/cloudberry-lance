/*-------------------------------------------------------------------------
 *
 * lance_fdw.h
 *	  Definitions shared by every lance_fdw module.
 *
 * Include this instead of <lance/lance.h> or <nanoarrow/nanoarrow.h>: both
 * declare the Arrow C data interface structs, but only nanoarrow.h defines the
 * ARROW_FLAG_* macros and it guards that whole block on
 * ARROW_FLAG_DICTIONARY_ORDERED.  Pulling in lance.h first would therefore
 * leave the flags undefined and make nanoarrow.h declare ArrowArrayStream a
 * second time, so the order below is not cosmetic.
 *
 * Copyright (c) 2026, Apache Cloudberry (incubating) contributors
 *
 * IDENTIFICATION
 *	  src/lance_fdw.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef LANCE_FDW_H
#define LANCE_FDW_H

#include "nanoarrow/nanoarrow.h"
#include "lance/lance.h"

/*
 * Row estimate used when the table carries no rows_hint option.  The planner
 * may not open the dataset (DESIGN I13: no I/O while planning), and lance-c
 * has no cheap row count anyway, so this is a constant (DESIGN Q11).
 */
#define LANCE_FDW_DEFAULT_ROWS 100000.0

#endif							/* LANCE_FDW_H */

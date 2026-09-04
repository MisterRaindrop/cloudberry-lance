/*-------------------------------------------------------------------------
 *
 * lance_dispatch.c
 *	  MPP dispatch of Lance fragments (DESIGN D2, D3).
 *
 * Cloudberry sends one plan to every segment; there is no mechanism for giving
 * each QE a different one.  So the split is not sent, it is recomputed: the QD
 * puts the whole fragment list into the plan, and every QE derives its own
 * share from values the statement already shares - the session id, the command
 * counter and its own segment index.  Two QEs of one statement therefore never
 * pick the same fragment, and between them they pick all of them (I2), without
 * a round trip.
 *
 * The randomising terms are what keeps a short fragment list from always
 * landing on segment 0; the model is gpcontrib/pxf_fdw, which has been running
 * this arithmetic in production.
 *
 * IDENTIFICATION
 *	  src/lance_dispatch.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <errno.h>
#include <stdlib.h>

#include "lance_fdw.h"
#include "lance_dispatch.h"

#include "cdb/cdbutil.h"
#include "cdb/cdbvars.h"
#include "lib/stringinfo.h"
#include "nodes/makefuncs.h"
#include "nodes/pg_list.h"
#include "utils/memutils.h"

#define LANCE_SCAN_UNIT_KIND "fragment"

/* Positions inside one scan unit list. */
#define LANCE_UNIT_KIND		0
#define LANCE_UNIT_URI		1
#define LANCE_UNIT_VERSION	2
#define LANCE_UNIT_IDS		3
#define LANCE_UNIT_NFIELDS	4

char *
lance_dispatch_ids_string(const uint64 *ids, int nids)
{
	StringInfoData buf;
	int			i;

	initStringInfo(&buf);
	for (i = 0; i < nids; i++)
	{
		if (i > 0)
			appendStringInfoChar(&buf, ' ');
		appendStringInfo(&buf, UINT64_FORMAT, ids[i]);
	}

	return buf.data;
}

static List *
lance_dispatch_make_units(const char *uri, uint64 version,
						  const uint64 *ids, int nids)
{
	List	   *unit = NIL;
	char	   *ids_text = lance_dispatch_ids_string(ids, nids);

	/*
	 * A dataset with no fragments would otherwise put an empty String node
	 * into the plan, and whether one of those survives plan serialisation is
	 * not something to bet an empty dataset on.  One space reads back as no
	 * ids, and spaces are escaped by the serialiser like any other.
	 */
	if (ids_text[0] == '\0')
		ids_text = pstrdup(" ");

	unit = lappend(unit, makeString(pstrdup(LANCE_SCAN_UNIT_KIND)));
	unit = lappend(unit, makeString(pstrdup(uri)));
	unit = lappend(unit, makeString(psprintf(UINT64_FORMAT, version)));
	unit = lappend(unit, makeString(ids_text));

	return unit;
}

/*
 * Give back a unit list this function put in the plan on an earlier execution.
 * Only this file ever writes that slot, so everything in it is ours to free.
 */
static void
lance_dispatch_free_units(List *units)
{
	ListCell   *lc;

	foreach(lc, units)
	{
		String	   *value = (String *) lfirst(lc);

		if (value == NULL || !IsA(value, String))
			continue;
		if (value->sval != NULL)
			pfree(value->sval);
		pfree(value);
	}

	list_free(units);
}

void
lance_dispatch_publish(ForeignScan *fsplan, const char *uri, uint64 version,
					   const uint64 *ids, int nids)
{
	/*
	 * The list has to outlive this executor run, because what reads it is the
	 * plan serialiser on the way to the segments - and, if this plan is a
	 * cached one, the next execution of the same statement.  So build it in
	 * whatever context the plan node itself lives in, and replace any units a
	 * previous execution left behind instead of appending a second set.
	 */
	MemoryContext plancxt = GetMemoryChunkContext(fsplan);
	MemoryContext oldcxt = MemoryContextSwitchTo(plancxt);
	List	   *units;

	units = lance_dispatch_make_units(uri, version, ids, nids);

	if (list_length(fsplan->fdw_private) > LANCE_FDW_PRIVATE_UNITS)
	{
		/*
		 * A cached plan reaches this a second time.  Freeing what the previous
		 * execution left is what keeps a prepared statement in a loop from
		 * growing the plan's memory context one uri and one fragment list at a
		 * time.
		 */
		lance_dispatch_free_units((List *) list_nth(fsplan->fdw_private,
													LANCE_FDW_PRIVATE_UNITS));
		fsplan->fdw_private = list_truncate(fsplan->fdw_private,
											LANCE_FDW_PRIVATE_UNITS);
	}

	fsplan->fdw_private = lappend(fsplan->fdw_private, units);

	MemoryContextSwitchTo(oldcxt);
}

static uint64
lance_dispatch_parse_uint64(const char *s, const char *what)
{
	char	   *endptr;
	unsigned long long parsed;

	errno = 0;
	parsed = strtoull(s, &endptr, 10);
	if (errno != 0 || endptr == s || *endptr != '\0')
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("lance_fdw: cannot read the %s in the plan", what),
				 errdetail("Found \"%s\".", s)));

	return (uint64) parsed;
}

/*
 * Split the space separated id list.  An empty string means no fragments,
 * which is what an empty dataset looks like.
 */
static void
lance_dispatch_parse_ids(const char *s, uint64 **ids, int *nids)
{
	const char *p;
	int			count = 0;
	int			i = 0;

	for (p = s; *p != '\0';)
	{
		while (*p == ' ')
			p++;
		if (*p == '\0')
			break;
		count++;
		while (*p != '\0' && *p != ' ')
			p++;
	}

	*nids = count;
	*ids = count > 0 ? (uint64 *) palloc(sizeof(uint64) * count) : NULL;

	for (p = s; *p != '\0';)
	{
		char	   *endptr;
		unsigned long long parsed;

		while (*p == ' ')
			p++;
		if (*p == '\0')
			break;

		errno = 0;
		parsed = strtoull(p, &endptr, 10);
		if (errno != 0 || endptr == p || (*endptr != ' ' && *endptr != '\0'))
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("lance_fdw: cannot read the fragment list in the plan"),
					 errdetail("Found \"%s\".", s)));

		(*ids)[i++] = (uint64) parsed;
		p = endptr;
	}

	Assert(i == count);
}

bool
lance_dispatch_read_units(const ForeignScan *fsplan, LanceScanUnits *out)
{
	List	   *unit;

	if (list_length(fsplan->fdw_private) <= LANCE_FDW_PRIVATE_UNITS)
		return false;

	unit = (List *) list_nth(fsplan->fdw_private, LANCE_FDW_PRIVATE_UNITS);
	if (list_length(unit) != LANCE_UNIT_NFIELDS)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("lance_fdw: the plan carries %d scan unit fields, expected %d",
						list_length(unit), LANCE_UNIT_NFIELDS)));

	memset(out, 0, sizeof(*out));
	out->kind = strVal(list_nth(unit, LANCE_UNIT_KIND));
	out->uri = strVal(list_nth(unit, LANCE_UNIT_URI));
	out->version = lance_dispatch_parse_uint64(strVal(list_nth(unit, LANCE_UNIT_VERSION)),
											   "dataset version");
	lance_dispatch_parse_ids(strVal(list_nth(unit, LANCE_UNIT_IDS)),
							 &out->ids, &out->nids);

	/*
	 * A unit kind this build does not know can only come from a newer plan,
	 * which is not something to guess at.
	 */
	if (strcmp(out->kind, LANCE_SCAN_UNIT_KIND) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("lance_fdw: unknown scan unit kind \"%s\"", out->kind)));

	return true;
}

int
lance_dispatch_take_share(uint64 *ids, int nids)
{
	int			nsegments = getgpsegmentCount();
	int			mysegment = GpIdentity.segindex;
	int64		shift;
	int			kept = 0;
	int			i;

	/*
	 * Not knowing how many segments there are, or which one this is, would
	 * turn a split into data loss.  Reading everything is the safe answer and
	 * cannot happen on a QE of a dispatched statement.
	 */
	if (nsegments <= 0 || mysegment < 0 || mysegment >= nsegments)
		return nids;

	/*
	 * Both terms are the same on every QE of one statement, which is the whole
	 * reason the shares agree.  They are normalised into [0, nsegments) first:
	 * C's % keeps the sign of its left operand, and a negative shift would
	 * leave some fragments belonging to no segment at all.
	 */
	shift = ((int64) gp_session_id % nsegments + (int64) gp_command_count) % nsegments;
	if (shift < 0)
		shift += nsegments;

	for (i = 0; i < nids; i++)
	{
		if ((i + shift) % nsegments == mysegment)
			ids[kept++] = ids[i];
	}

	return kept;
}

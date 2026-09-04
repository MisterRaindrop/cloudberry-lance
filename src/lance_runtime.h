/*-------------------------------------------------------------------------
 *
 * lance_runtime.h
 *	  Per-backend lance-c runtime: session, error translation and the handle
 *	  registry that keeps ResourceOwner release honest.
 *
 * IDENTIFICATION
 *	  src/lance_runtime.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef LANCE_RUNTIME_H
#define LANCE_RUNTIME_H

#include "lance_fdw.h"

/* GUCs, registered by lance_rt_define_gucs() from _PG_init() */
extern int	lance_cpu_threads;
extern int	lance_io_threads;
extern int	lance_index_cache_mb;
extern int	lance_metadata_cache_mb;

extern void lance_rt_define_gucs(void);

/* Hook the handle registry onto ResourceOwner release; call once, at load. */
extern void lance_rt_register_callback(void);

/*
 * Bring the lance-c runtime up.  Cheap and idempotent after the first call;
 * every entry point that is about to touch lance-c calls it first.
 */
extern void lance_rt_init(void);

/* The shared session all datasets of this backend are opened with (DESIGN D9). */
extern LanceSession *lance_rt_session(void);

/*
 * Handle registry (DESIGN D12).  Anything that lance-c hands out lives outside
 * palloc, so it is registered against the current ResourceOwner and closed
 * exactly once - by lance_rt_release() on the normal path, or by the resource
 * owner callback on the ERROR/abort path.
 */
typedef struct LanceHandle LanceHandle;

extern LanceHandle *lance_rt_track_dataset(LanceDataset *dataset);
extern LanceHandle *lance_rt_track_scanner(LanceScanner *scanner);

/*
 * Hand out a zeroed ArrowArrayStream that is already registered.  The struct
 * itself is owned by the registry so that it outlives any executor context
 * that might be torn down before the resource owner runs.
 */
extern struct ArrowArrayStream *lance_rt_track_new_stream(LanceHandle **handle);

/* Close the underlying object and forget the handle.  NULL is accepted. */
extern void lance_rt_release(LanceHandle *handle);

/* Forget the handle without closing it (ownership moved elsewhere). */
extern void lance_rt_forget(LanceHandle *handle);

/*
 * Turn the thread-local lance-c error into an ereport(ERROR) (DESIGN D11).
 * uri may be NULL.
 */
extern void lance_rt_error(const char *uri) pg_attribute_noreturn();

/*
 * Every lance-c call goes through this.  `ok` is the call's success condition
 * - a non-NULL handle, or a zero int32 return.
 */
#define LANCE_CHECK(ok, uri) \
	do { \
		if (!(ok)) \
			lance_rt_error(uri); \
	} while (0)

#endif							/* LANCE_RUNTIME_H */

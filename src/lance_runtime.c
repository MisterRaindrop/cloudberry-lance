/*-------------------------------------------------------------------------
 *
 * lance_runtime.c
 *	  Per-backend lance-c runtime.
 *
 * Three jobs, all of them about keeping a Rust async runtime inside a
 * PostgreSQL backend well behaved:
 *
 *	- lance_rt_init() creates the one LanceSession this backend uses, with the
 *	  full signal mask blocked so the tokio worker threads that lance-c spawns
 *	  inherit a blocked mask and PostgreSQL's SIGINT/SIGTERM/SIGUSR1 keep going
 *	  to the main thread only (DESIGN D10, I5).
 *
 *	- lance_rt_error() turns lance-c's thread-local error into an ereport with
 *	  a "lance: " prefix and the error code in the detail (DESIGN D11).
 *
 *	- the handle registry closes datasets, scanners and Arrow streams exactly
 *	  once, on the normal path and on the ERROR/abort path alike (DESIGN D12,
 *	  I6).
 *
 * IDENTIFICATION
 *	  src/lance_runtime.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <pthread.h>
#include <signal.h>

#include "lance_fdw.h"
#include "lance_runtime.h"

#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/resowner.h"

int			lance_cpu_threads = 0;
int			lance_io_threads = 0;
int			lance_index_cache_mb = 64;
int			lance_metadata_cache_mb = 32;

typedef enum LanceHandleKind
{
	LANCE_HANDLE_DATASET,
	LANCE_HANDLE_SCANNER,
	LANCE_HANDLE_STREAM
} LanceHandleKind;

struct LanceHandle
{
	LanceHandleKind kind;
	ResourceOwner owner;
	LanceDataset *dataset;
	LanceScanner *scanner;
	struct ArrowArrayStream stream;
	struct LanceHandle *prev;
	struct LanceHandle *next;
};

static LanceSession *rt_session = NULL;
static bool rt_callback_registered = false;
static LanceHandle *rt_handles = NULL;

static void lance_rt_release_callback(ResourceReleasePhase phase,
									  bool isCommit,
									  bool isTopLevel,
									  void *arg);

/*
 * Register the GUCs.  Deliberately no MarkGUCPrefixReserved(): nothing here
 * needs the prefix locked down, and leaving it open keeps -c lance_fdw.* usable
 * for future placeholders.
 */
void
lance_rt_define_gucs(void)
{
	DefineCustomIntVariable("lance_fdw.cpu_threads",
							"Number of CPU worker threads lance-c may use.",
							"0 leaves lance-c at its own default, which scales "
							"with the number of cores. Only read once, before "
							"the first lance-c call in a backend.",
							&lance_cpu_threads,
							0, 0, 1024,
							PGC_SUSET,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("lance_fdw.io_threads",
							"Number of I/O threads lance-c may use.",
							"0 leaves lance-c at its own default. Only read "
							"once, before the first lance-c call in a backend.",
							&lance_io_threads,
							0, 0, 1024,
							PGC_SUSET,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("lance_fdw.index_cache_size_mb",
							"Size of the per-backend Lance index cache, in MB.",
							"lance's own default is 6 GiB, which is far too "
							"much for one cache per backend. This block reads "
							"no indexes, so a small number is fine.",
							&lance_index_cache_mb,
							64, 0, 1024 * 1024,
							PGC_SUSET,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("lance_fdw.metadata_cache_size_mb",
							"Size of the per-backend Lance metadata cache, in MB.",
							"lance's own default is 1 GiB. The cache is shared "
							"by every dataset this backend opens.",
							&lance_metadata_cache_mb,
							32, 0, 1024 * 1024,
							PGC_SUSET,
							0,
							NULL, NULL, NULL);
}

/*
 * Map a lance-c error code onto an SQLSTATE (DESIGN D11).
 */
static int
lance_rt_errcode(LanceErrorCode code)
{
	switch (code)
	{
		case LANCE_ERR_NOT_FOUND:
			return ERRCODE_FDW_TABLE_NOT_FOUND;
		case LANCE_ERR_IO:
			return ERRCODE_IO_ERROR;
		case LANCE_ERR_INVALID_ARGUMENT:
			return ERRCODE_INVALID_PARAMETER_VALUE;
		case LANCE_ERR_NOT_SUPPORTED:
			return ERRCODE_FEATURE_NOT_SUPPORTED;
		case LANCE_ERR_DATASET_ALREADY_EXISTS:
			return ERRCODE_DUPLICATE_OBJECT;
		case LANCE_ERR_COMMIT_CONFLICT:
			return ERRCODE_T_R_SERIALIZATION_FAILURE;
		case LANCE_ERR_INDEX:
		case LANCE_ERR_INTERNAL:
		case LANCE_ERR_PANIC:
		case LANCE_OK:
		default:
			return ERRCODE_INTERNAL_ERROR;
	}
}

void
lance_rt_error(const char *uri)
{
	LanceErrorCode code = lance_last_error_code();
	const char *raw = lance_last_error_message();
	char	   *message;

	/*
	 * Copy the message out of lance-c's thread-local storage before anything
	 * can longjmp past the free.
	 */
	if (raw != NULL)
	{
		message = pstrdup(raw);
		lance_free_string(raw);
	}
	else
		message = pstrdup("unknown error");

	if (uri != NULL)
		ereport(ERROR,
				(errcode(lance_rt_errcode(code)),
				 errmsg("lance: %s", message),
				 errdetail("lance error code %d, uri %s", (int) code, uri)));
	else
		ereport(ERROR,
				(errcode(lance_rt_errcode(code)),
				 errmsg("lance: %s", message),
				 errdetail("lance error code %d", (int) code)));
}

/*
 * Thread count environment variables have to be in place before the first
 * lance-c call, because that is when the runtimes are built (PROBES Q7).
 */
static void
lance_rt_set_thread_limits(void)
{
	char		buf[32];

	if (lance_cpu_threads > 0)
	{
		snprintf(buf, sizeof(buf), "%d", lance_cpu_threads);
		if (setenv("LANCE_CPU_THREADS", buf, 1) != 0)
			ereport(WARNING,
					(errmsg("lance_fdw: could not set LANCE_CPU_THREADS")));
	}

	if (lance_io_threads > 0)
	{
		snprintf(buf, sizeof(buf), "%d", lance_io_threads);
		if (setenv("LANCE_IO_THREADS", buf, 1) != 0)
			ereport(WARNING,
					(errmsg("lance_fdw: could not set LANCE_IO_THREADS")));
	}
}

void
lance_rt_init(void)
{
	sigset_t	blocked;
	sigset_t	saved;
	LanceSession *session;
	int			rc;

	if (rt_session != NULL)
		return;

	lance_rt_set_thread_limits();

	/*
	 * Everything lance-c spawns from here inherits this mask, so no worker
	 * thread will ever run a PostgreSQL signal handler (I5).
	 */
	sigfillset(&blocked);
	rc = pthread_sigmask(SIG_BLOCK, &blocked, &saved);
	if (rc != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("lance_fdw: could not block signals"),
				 errdetail("pthread_sigmask() returned %d.", rc)));

	session = lance_session_new((uint64_t) lance_index_cache_mb * 1024 * 1024,
								(uint64_t) lance_metadata_cache_mb * 1024 * 1024);

	/* Restore before reporting anything: ereport must not run masked. */
	(void) pthread_sigmask(SIG_SETMASK, &saved, NULL);

	LANCE_CHECK(session != NULL, NULL);

	rt_session = session;
}

LanceSession *
lance_rt_session(void)
{
	lance_rt_init();
	return rt_session;
}

/*
 * Handle registry
 */
static LanceHandle *
lance_rt_track(LanceHandleKind kind)
{
	LanceHandle *handle;

	Assert(rt_callback_registered);

	handle = (LanceHandle *) MemoryContextAllocZero(TopMemoryContext,
													sizeof(LanceHandle));
	handle->kind = kind;
	handle->owner = CurrentResourceOwner;
	handle->next = rt_handles;
	if (rt_handles != NULL)
		rt_handles->prev = handle;
	rt_handles = handle;

	return handle;
}

LanceHandle *
lance_rt_track_dataset(LanceDataset *dataset)
{
	LanceHandle *handle = lance_rt_track(LANCE_HANDLE_DATASET);

	handle->dataset = dataset;
	return handle;
}

LanceHandle *
lance_rt_track_scanner(LanceScanner *scanner)
{
	LanceHandle *handle = lance_rt_track(LANCE_HANDLE_SCANNER);

	handle->scanner = scanner;
	return handle;
}

struct ArrowArrayStream *
lance_rt_track_new_stream(LanceHandle **handle)
{
	LanceHandle *h = lance_rt_track(LANCE_HANDLE_STREAM);

	*handle = h;
	return &h->stream;
}

static void
lance_rt_unlink(LanceHandle *handle)
{
	if (handle->prev != NULL)
		handle->prev->next = handle->next;
	else
		rt_handles = handle->next;

	if (handle->next != NULL)
		handle->next->prev = handle->prev;

	handle->prev = handle->next = NULL;
}

void
lance_rt_forget(LanceHandle *handle)
{
	if (handle == NULL)
		return;

	lance_rt_unlink(handle);
	pfree(handle);
}

void
lance_rt_release(LanceHandle *handle)
{
	if (handle == NULL)
		return;

	switch (handle->kind)
	{
		case LANCE_HANDLE_DATASET:
			lance_dataset_close(handle->dataset);
			handle->dataset = NULL;
			break;
		case LANCE_HANDLE_SCANNER:
			lance_scanner_close(handle->scanner);
			handle->scanner = NULL;
			break;
		case LANCE_HANDLE_STREAM:
			/* The Arrow contract says release runs exactly once. */
			if (handle->stream.release != NULL)
			{
				handle->stream.release(&handle->stream);
				handle->stream.release = NULL;
			}
			break;
	}

	lance_rt_forget(handle);
}

static const char *
lance_rt_kind_name(LanceHandleKind kind)
{
	switch (kind)
	{
		case LANCE_HANDLE_DATASET:
			return "dataset";
		case LANCE_HANDLE_SCANNER:
			return "scanner";
		case LANCE_HANDLE_STREAM:
			return "array stream";
	}
	return "handle";
}

static void
lance_rt_release_callback(ResourceReleasePhase phase,
						  bool isCommit,
						  bool isTopLevel,
						  void *arg)
{
	LanceHandle *handle;

	if (phase != RESOURCE_RELEASE_BEFORE_LOCKS)
		return;

	handle = rt_handles;
	while (handle != NULL)
	{
		LanceHandle *next = handle->next;

		if (handle->owner == CurrentResourceOwner)
		{
			/*
			 * Reaching this on a successful commit means some path forgot to
			 * release; say so, then clean up anyway.
			 */
			if (isCommit)
				elog(WARNING, "lance_fdw: leaked Lance %s handle",
					 lance_rt_kind_name(handle->kind));

			lance_rt_release(handle);
		}

		handle = next;
	}
}

/*
 * Called from _PG_init().
 */
void
lance_rt_register_callback(void)
{
	if (rt_callback_registered)
		return;

	RegisterResourceReleaseCallback(lance_rt_release_callback, NULL);
	rt_callback_registered = true;
}

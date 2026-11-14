// SPDX-License-Identifier: GPL-2.0
/*
 * Adapted from Jimmy Zuber's write_extend_eof_test.c, [PATCH v4 2/2],
 * Message-ID: <20260824143052.1546163-3-jamz@amazon.com>
 * https://lists.openwall.net/linux-kernel/2026/08/24/1443
 *
 * Retains all four cases and their decisive page-sized pread, without the
 * kernel selftest harness. Run as root in a disposable Linux guest:
 *   cc -O2 -Wall -Wextra -pthread eof-probe.c -o eof-probe
 *   ./eof-probe cached       # write-through, FOPEN_KEEP_CACHE
 *   ./eof-probe direct-mmap  # DIRECT_IO + negotiated shared mmap, no KEEP_CACHE
 *   ./eof-probe cached-odirect # cached FUSE open, aligned application O_DIRECT
 * Exit: 0 all exact-byte oracles pass; 1 regression; 2 prerequisite/runtime
 * failure; 64 bad arguments. Neither mode enables FUSE_WRITEBACK_CACHE.
 *
 * Each case owns a fresh /tmp/fuse_weof_XXXXXX mount and in-memory backing.
 * Snapshots inspect server memory, not the mounted file: no flush, close,
 * reopen or extra client read precedes the decisive upstream pread. The
 * mutex orders snapshots with every server request. The pread window reports
 * backing changes, not a claim that background writeback cannot occur there.
 */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fuse.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

#if FUSE_KERNEL_MINOR_VERSION < 39 || !defined(FUSE_DIRECT_IO_ALLOW_MMAP)
#error "Linux FUSE protocol >= 7.39 headers required (DIRECT_IO_ALLOW_MMAP)"
#endif

#define FILE_INO 2
#define MAX_WRITE (128 * 1024)
#define BACKING_SIZE (4 * 1024 * 1024)
#define POLLUTE 0xee

struct server {
	int fd, stop_fd, direct, initialized, failed, device_closed;
	long page;
	const char *name, *phase;
	pthread_mutex_t lock;
	uint64_t size, writes;
	unsigned char backing[BACKING_SIZE];
};

static volatile sig_atomic_t interrupted;

static void on_signal(int sig)
{
	interrupted = sig;
}

static void fill_attr(struct fuse_attr *a, uint64_t ino, uint32_t mode,
		      uint64_t size, long page)
{
	memset(a, 0, sizeof(*a));
	a->ino = ino;
	a->mode = mode;
	a->nlink = 1;
	a->size = size;
	a->blksize = page;
}

/* Called only by the responder, with the state mutex held. */
static int reply(struct server *s, uint64_t unique, int error,
		 const void *data, size_t len)
{
	struct fuse_out_header out = {
		.len = sizeof(out) + len, .error = error, .unique = unique,
	};
	struct iovec iov[] = { { &out, sizeof(out) }, { (void *)data, len } };
	ssize_t n;

	do {
		n = writev(s->fd, iov, len ? 2 : 1);
	} while (n < 0 && errno == EINTR);
	/* An interrupted client request may already have been discarded. */
	if (n < 0 && errno == ENOENT)
		return 0;
	if (n != (ssize_t)out.len) {
		fprintf(stderr, "case=%s server_reply_error errno=%d bytes=%zd\n",
			s->name, n < 0 ? errno : EIO, n);
		return -1;
	}
	return 0;
}

static int dispatch(struct server *s, struct fuse_in_header *h, size_t len)
{
	void *payload = h + 1;
	size_t need = 0;

	switch (h->opcode) {
	case FUSE_INIT: need = 4 * sizeof(uint32_t); break;
	case FUSE_OPEN: case FUSE_OPENDIR: need = sizeof(struct fuse_open_in); break;
	case FUSE_READ: need = sizeof(struct fuse_read_in); break;
	case FUSE_WRITE: need = sizeof(struct fuse_write_in); break;
	case FUSE_SETATTR: need = sizeof(struct fuse_setattr_in); break;
	case FUSE_FALLOCATE: need = sizeof(struct fuse_fallocate_in); break;
	default: break;
	}
	if (len < need)
		return reply(s, h->unique, -EINVAL, NULL, 0);

	switch (h->opcode) {
	case FUSE_INIT: {
		struct fuse_init_in *in = payload;
		struct fuse_init_out out = {0};
		uint64_t offered = in->flags;
		uint64_t chosen = FUSE_MAX_PAGES;
		unsigned minor = in->minor < FUSE_KERNEL_MINOR_VERSION ?
			in->minor : FUSE_KERNEL_MINOR_VERSION;

		if ((in->flags & FUSE_INIT_EXT) &&
		    len >= sizeof(struct fuse_init_in))
			offered |= (uint64_t)in->flags2 << 32;
		printf("case=%s init kernel=%u.%u offered=0x%016" PRIx64 "\n",
		       s->name, in->major, in->minor, offered);
		if (in->major != FUSE_KERNEL_VERSION || minor < 28 ||
		    !(offered & FUSE_MAX_PAGES) ||
		    (s->direct == 1 && (minor < 39 || !(offered & FUSE_INIT_EXT) ||
				 !(offered & FUSE_DIRECT_IO_ALLOW_MMAP)))) {
			fprintf(stderr, "case=%s prerequisite=unsupported_FUSE_capability mode=%s\n",
				s->name, s->direct == 1 ? "direct-mmap" : "cached");
			s->failed = 1;
			return reply(s, h->unique, -EOPNOTSUPP, NULL, 0);
		}
		if (s->direct == 1)
			chosen |= FUSE_INIT_EXT | FUSE_DIRECT_IO_ALLOW_MMAP;
		out.major = FUSE_KERNEL_VERSION;
		out.minor = minor;
		out.max_readahead = in->max_readahead;
		out.max_write = MAX_WRITE;
		out.max_background = 16;
		out.congestion_threshold = 12;
		out.flags = (uint32_t)chosen;
		out.flags2 = (uint32_t)(chosen >> 32);
		out.max_pages = MAX_WRITE / s->page;
		s->initialized = 1;
		printf("case=%s negotiated=%u.%u flags=0x%08x flags2=0x%08x writeback_cache=0 shared_direct_mmap=%d\n",
		       s->name, out.major, out.minor, out.flags, out.flags2, s->direct == 1);
		return reply(s, h->unique, 0, &out, sizeof(out));
	}
	case FUSE_GETATTR: {
		struct fuse_attr_out out = { .attr_valid = 3600 };
		int root = h->nodeid == FUSE_ROOT_ID;

		fill_attr(&out.attr, h->nodeid,
			  root ? S_IFDIR | 0755 : S_IFREG | 0644,
			  root ? 0 : s->size, s->page);
		return reply(s, h->unique, 0, &out, sizeof(out));
	}
	case FUSE_LOOKUP: {
		struct fuse_entry_out out = {
			.nodeid = FILE_INO, .attr_valid = 3600, .entry_valid = 3600,
		};

		if (h->nodeid != FUSE_ROOT_ID || len != sizeof("file") ||
		    memcmp(payload, "file", sizeof("file")))
			return reply(s, h->unique, -ENOENT, NULL, 0);
		fill_attr(&out.attr, FILE_INO, S_IFREG | 0644, s->size, s->page);
		return reply(s, h->unique, 0, &out, sizeof(out));
	}
	case FUSE_OPEN: case FUSE_OPENDIR: {
		struct fuse_open_out out = {0};

		if (h->opcode == FUSE_OPEN) {
			out.open_flags = s->direct == 1 ? FOPEN_DIRECT_IO : FOPEN_KEEP_CACHE;
			printf("case=%s open_flags=0x%x\n", s->name, out.open_flags);
		}
		return reply(s, h->unique, 0, &out, sizeof(out));
	}
	case FUSE_READ: {
		struct fuse_read_in *in = payload;
		uint64_t off = in->offset;
		size_t count = off < s->size ? s->size - off : 0;

		if (count > in->size)
			count = in->size;
		printf("case=%s phase=%s READ offset=%" PRIu64 " requested=%u returned=%zu\n",
		       s->name, s->phase, off, in->size, count);
		return reply(s, h->unique, 0, count ? s->backing + off : NULL, count);
	}
	case FUSE_WRITE: {
		struct fuse_write_in *in = payload;
		struct fuse_write_out out = { .size = in->size };
		uint64_t off = in->offset;
		size_t polluted = 0;

		if (in->size > len - sizeof(*in) || off > BACKING_SIZE ||
		    in->size > BACKING_SIZE - off)
			return reply(s, h->unique, -EFBIG, NULL, 0);
		for (size_t i = 0; i < in->size; i++)
			polluted += ((unsigned char *)(in + 1))[i] == POLLUTE;
		memcpy(s->backing + off, in + 1, in->size);
		if (off + in->size > s->size)
			s->size = off + in->size;
		printf("case=%s phase=%s WRITE seq=%" PRIu64 " offset=%" PRIu64
		       " length=%u write_flags=0x%x ee_bytes=%zu\n",
		       s->name, s->phase, ++s->writes, off, in->size,
		       in->write_flags, polluted);
		return reply(s, h->unique, 0, &out, sizeof(out));
	}
	case FUSE_SETATTR: {
		struct fuse_setattr_in *in = payload;
		struct fuse_attr_out out = { .attr_valid = 3600 };

		if (in->valid & FATTR_SIZE) {
			if (in->size > BACKING_SIZE)
				return reply(s, h->unique, -EFBIG, NULL, 0);
			/* Newly exposed bytes, including after truncation, are zero. */
			if (in->size < s->size)
				memset(s->backing + in->size, 0, s->size - in->size);
			else
				memset(s->backing + s->size, 0, in->size - s->size);
			s->size = in->size;
			printf("case=%s phase=%s SETATTR size=%" PRIu64 "\n",
			       s->name, s->phase, s->size);
		}
		fill_attr(&out.attr, FILE_INO, S_IFREG | 0644, s->size, s->page);
		return reply(s, h->unique, 0, &out, sizeof(out));
	}
	case FUSE_FALLOCATE: {
		struct fuse_fallocate_in *in = payload;
		uint64_t end;

		if (in->mode || in->offset > BACKING_SIZE ||
		    in->length > BACKING_SIZE - in->offset)
			return reply(s, h->unique, -EOPNOTSUPP, NULL, 0);
		end = in->offset + in->length;
		if (end > s->size) {
			memset(s->backing + s->size, 0, end - s->size);
			s->size = end;
		}
		printf("case=%s phase=%s FALLOCATE offset=%" PRIu64 " length=%" PRIu64 "\n",
		       s->name, s->phase, (uint64_t)in->offset, (uint64_t)in->length);
		return reply(s, h->unique, 0, NULL, 0);
	}
	case FUSE_FLUSH: case FUSE_RELEASE: case FUSE_RELEASEDIR:
	case FUSE_FSYNC: case FUSE_ACCESS: case FUSE_DESTROY:
		return reply(s, h->unique, 0, NULL, 0);
	case FUSE_FORGET: case FUSE_BATCH_FORGET:
		return 0;
	default:
		printf("case=%s unexpected_opcode=%u\n", s->name, h->opcode);
		return reply(s, h->unique, -EOPNOTSUPP, NULL, 0);
	}
}

static void *server_thread(void *arg)
{
	struct server *s = arg;
	union {
		struct fuse_in_header align;
		unsigned char bytes[MAX_WRITE + 4096];
	} buf;
	struct pollfd fds[] = {
		{ .fd = s->fd, .events = POLLIN },
		{ .fd = s->stop_fd, .events = POLLIN },
	};

	for (;;) {
		int ready = poll(fds, 2, -1);
		if (ready < 0 && errno == EINTR)
			continue;
		if (ready > 0 && fds[1].revents)
			return NULL;
		ssize_t n = ready < 0 ? -1 : read(s->fd, buf.bytes, sizeof(buf.bytes));
		struct fuse_in_header *h = (void *)buf.bytes;
		int bad;

		if (n < 0 && (errno == EINTR || errno == EAGAIN))
			continue;
		if (n < 0 && errno == ENODEV)
			return NULL; /* Our unmount disconnected the device. */
		pthread_mutex_lock(&s->lock);
		bad = n < (ssize_t)sizeof(*h) || h->len != (size_t)n;
		if (bad || dispatch(s, h, n - sizeof(*h)) < 0) {
			fprintf(stderr, "case=%s server_stopped bytes=%zd errno=%d\n",
				s->name, n, n < 0 ? errno : EPROTO);
			s->failed = 1;
			/* Abort pending requests instead of leaving the client stuck. */
			close(s->fd);
			s->device_closed = 1;
			pthread_mutex_unlock(&s->lock);
			return NULL;
		}
		pthread_mutex_unlock(&s->lock);
	}
}

/* Lossless [start,end)=hex-byte runs, not a checksum or sampled assertion. */
static void print_bytes(const unsigned char *bytes, size_t count)
{
	for (size_t i = 0, end; i < count; i = end) {
		for (end = i + 1; end < count && bytes[end] == bytes[i]; end++)
			;
		printf(" [%zu,%zu)=%02x", i, end, bytes[i]);
	}
	putchar('\n');
}

/* Snapshot and phase transition are atomic relative to server requests. */
static int snapshot(struct server *s, const char *stage, const char *next,
		    const unsigned char *expected, size_t expected_size,
		    size_t span, unsigned char *previous, uint64_t *prev_writes)
{
	size_t mismatch = span, changed = 0, ee = 0;
	int valid;

	pthread_mutex_lock(&s->lock);
	for (size_t i = 0; i < span; i++) {
		if (s->backing[i] != expected[i] && mismatch == span)
			mismatch = i;
		changed += s->backing[i] != previous[i];
		ee += s->backing[i] == POLLUTE;
	}
	valid = s->initialized && !s->failed && s->size == expected_size && mismatch == span;
	printf("case=%s snapshot=%s size=%" PRIu64 " expected_size=%zu inspected=%zu"
	       " writes=%" PRIu64 " writes_since_snapshot=%" PRIu64
	       " changed_bytes=%zu ee_bytes=%zu exact_backing=%s",
	       s->name, stage, s->size, expected_size, span, s->writes,
	       s->writes - *prev_writes, changed, ee, valid ? "PASS" : "FAIL");
	if (mismatch != span)
		printf(" first_mismatch=%zu got=%02x want=%02x", mismatch,
		       s->backing[mismatch], expected[mismatch]);
	putchar('\n');
	printf("case=%s backing=%s runs:", s->name, stage);
	print_bytes(s->backing, span);
	memcpy(previous, s->backing, span);
	*prev_writes = s->writes;
	s->phase = next;
	pthread_mutex_unlock(&s->lock);
	return valid;
}

static int run_case(int which, int direct, long page)
{
	static const char *const names[] = {
		"write_extend", "ftruncate_extend", "fallocate_extend",
		"extend_into_eof_page_preserves_data",
	};
	struct server *s = calloc(1, sizeof(*s));
	pthread_t thread;
	char dir[] = "/tmp/fuse_weof_XXXXXX", opts[128], path[128];
	unsigned char *expected = NULL, *previous = NULL, *rd = NULL, *map = MAP_FAILED;
	size_t span = 8 * page, eof = 2 * page + page / 4, base = 2 * page;
	size_t write_size = which == 3 ? 2 * page : direct == 2 ? page : 4;
	size_t position = which == 3 ? base + 3 * page / 4 :
		direct == 2 ? 5 * page : 5 * page + page / 3;
	size_t final_size = which == 1 ? 8 * page : which == 2 ? eof + 4 * page :
		position + write_size;
	uint64_t prev_writes = 0;
	int fd = -1, mounted = 0, started = 0, made_dir = 0, rc = 2, err;
	sigset_t blocked, oldmask;
	ssize_t n;

	if (!s) {
		perror("calloc server");
		return 2;
	}
	s->fd = -1;
	s->stop_fd = -1;
	s->direct = direct;
	s->page = page;
	s->name = names[which];
	s->phase = "setup";
	err = pthread_mutex_init(&s->lock, NULL);
	if (err) {
		fprintf(stderr, "pthread_mutex_init: %s\n", strerror(err));
		free(s);
		return 2;
	}
#define REQUIRE(expr) do { \
	if (!(expr) || interrupted) { \
		fprintf(stderr, "case=%s prerequisite_or_syscall_failed=%s errno=%d signal=%d\n", \
			s->name, #expr, errno, (int)interrupted); \
		goto cleanup; \
	} \
} while (0)
	expected = calloc(1, span);
	previous = calloc(1, span);
	REQUIRE(posix_memalign((void **)&rd, page, 2 * page) == 0);
	REQUIRE(expected && previous && rd);
	s->stop_fd = eventfd(0, EFD_CLOEXEC);
	REQUIRE(s->stop_fd >= 0);
	s->fd = open("/dev/fuse", O_RDWR | O_CLOEXEC | O_NONBLOCK);
	REQUIRE(s->fd >= 0);
	made_dir = mkdtemp(dir) != NULL;
	REQUIRE(made_dir);
	snprintf(opts, sizeof(opts), "fd=%d,rootmode=40000,user_id=0,group_id=0", s->fd);
	err = mount("fuse-eof-probe", dir, "fuse", MS_NOSUID | MS_NODEV, opts);
	mounted = err == 0;
	REQUIRE(mounted);
	printf("case=%s mount=%s old_eof=%zu page_base=%zu final_size=%zu\n",
	       s->name, dir, eof, base, final_size);
	/* Only the client handles interruption; no asynchronous cancellation. */
	sigemptyset(&blocked);
	sigaddset(&blocked, SIGINT);
	sigaddset(&blocked, SIGTERM);
	sigaddset(&blocked, SIGHUP);
	err = pthread_sigmask(SIG_BLOCK, &blocked, &oldmask);
	REQUIRE(err == 0);
	err = pthread_create(&thread, NULL, server_thread, s);
	if (!err)
		started = 1;
	pthread_sigmask(SIG_SETMASK, &oldmask, NULL);
	REQUIRE(err == 0);
	snprintf(path, sizeof(path), "%s/file", dir);
	fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	REQUIRE(fd >= 0);
	memset(expected, 'A', eof);
	REQUIRE(pwrite(fd, expected, eof, 0) == (ssize_t)eof);
	map = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
	REQUIRE(map != MAP_FAILED);
	if (direct == 2) {
		int flags = fcntl(fd, F_GETFL);
		REQUIRE(flags >= 0);
		REQUIRE(fcntl(fd, F_SETFL, flags | O_DIRECT) == 0);
		REQUIRE(fcntl(fd, F_GETFL) & O_DIRECT);
		printf("case=%s client_odirect=1\n", s->name);
	}
	memset(map + page / 4, POLLUTE, 3 * page / 4);
	for (long i = page / 4; i < page; i++)
		REQUIRE(((volatile unsigned char *)map)[i] == POLLUTE);
	printf("case=%s precondition=shared_mmap_post_EOF_pollution PASS range=[%zu,%zu) byte=ee\n",
	       s->name, eof, base + page);
	REQUIRE(snapshot(s, "before_extension", "extension", expected, eof,
			 span, previous, &prev_writes));

	/* The upstream four extending syscalls, with no intervening file flush. */
	if (which == 0) {
		const unsigned char *value = (const unsigned char *)"data";
		if (direct == 2) {
			memset(rd, 'D', write_size);
			value = rd;
		}
		REQUIRE(pwrite(fd, value, write_size, position) == (ssize_t)write_size);
		memcpy(expected + position, value, write_size);
	} else if (which == 1) {
		REQUIRE(ftruncate(fd, final_size) == 0);
	} else if (which == 2) {
		REQUIRE(fallocate(fd, 0, eof, 4 * page) == 0);
	} else {
		memset(rd, 'B', 2 * page);
		REQUIRE(pwrite(fd, rd, 2 * page, position) == 2 * page);
		memset(expected + position, 'B', 2 * page);
	}
	/* Backing FAIL is evidence, not a reason to skip the client oracle. */
	int backing_after_extension = snapshot(s, "after_extension", "decisive_pread",
		expected, final_size, span, previous, &prev_writes);
	n = pread(fd, rd, page, base);
	int backing_after_pread = snapshot(s, "after_decisive_pread", "cleanup",
		expected, final_size, span, previous, &prev_writes);
	REQUIRE(n >= 0);
	size_t mismatch = 0;
	while (mismatch < (size_t)n && mismatch < (size_t)page &&
	       rd[mismatch] == expected[base + mismatch])
		mismatch++;
	int exact = n == page && mismatch == (size_t)page;
	pthread_mutex_lock(&s->lock);
	printf("case=%s client=decisive_pread offset=%zu requested=%ld returned=%zd exact_bytes=%s",
	       s->name, base, page, n, exact ? "PASS" : "FAIL");
	if (mismatch < (size_t)n && mismatch < (size_t)page)
		printf(" first_mismatch=%zu got=%02x want=%02x", base + mismatch,
		       rd[mismatch], expected[base + mismatch]);
	putchar('\n');
	printf("case=%s client_page_runs_relative_to=%zu:", s->name, base);
	print_bytes(rd, n);
	pthread_mutex_unlock(&s->lock);
	rc = exact && backing_after_extension && backing_after_pread ? 0 : 1;

cleanup:
	/* Unmap/close only after the decisive observations; never cancel a thread. */
	if (map != MAP_FAILED && munmap(map, page) < 0) {
		perror("munmap owned mapping");
		rc = 2;
	}
	if (fd >= 0 && close(fd) < 0) {
		perror("close owned file");
		rc = 2;
	}
	if (mounted && umount2(dir, 0) < 0) {
		perror("unmount owned probe mount; attempting explicit detach");
		rc = 2;
		if (umount2(dir, MNT_DETACH) < 0) {
			fprintf(stderr, "LIVE_OWNED_MOUNT=%s detach_errno=%d\n", dir, errno);
		}
	}
	if (started) {
		uint64_t stop = 1;
		ssize_t sent;

		/* Wake a poll, not a cancelled/closed blocking read in another thread. */
		do {
			sent = write(s->stop_fd, &stop, sizeof(stop));
		} while (sent < 0 && errno == EINTR);
		if (sent != (ssize_t)sizeof(stop)) {
			fprintf(stderr, "responder_stop_failed owned_mount=%s errno=%d\n", dir, errno);
			exit(2);
		}
		err = pthread_join(thread, NULL);
		if (err) {
			fprintf(stderr, "pthread_join: %s\n", strerror(err));
			/* Do not free memory that a responder might still use. */
			exit(2);
		}
	}
	if (s->failed)
		rc = 2;
	if (s->fd >= 0 && !s->device_closed)
		close(s->fd);
	if (s->stop_fd >= 0)
		close(s->stop_fd);
	if (made_dir && rmdir(dir) < 0) {
		fprintf(stderr, "owned_directory_retained=%s errno=%d\n", dir, errno);
		rc = 2;
	}
	pthread_mutex_destroy(&s->lock);
	free(rd);
	free(previous);
	free(expected);
	free(s);
	printf("case=%s result=%s exit=%d\n", names[which],
	       rc == 0 ? "PASS" : rc == 1 ? "REGRESSION" : "ERROR", rc);
	return rc;
#undef REQUIRE
}

int main(int argc, char **argv)
{
	struct sigaction action = { .sa_handler = on_signal };
	long page = sysconf(_SC_PAGESIZE);
	int direct, result = 0;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc != 2 || (strcmp(argv[1], "cached") && strcmp(argv[1], "direct-mmap") &&
			 strcmp(argv[1], "cached-odirect"))) {
		fprintf(stderr, "usage: %s cached|direct-mmap|cached-odirect\n", argv[0]);
		return 64;
	}
	direct = !strcmp(argv[1], "direct-mmap") ? 1 :
		 !strcmp(argv[1], "cached-odirect") ? 2 : 0;
	printf("preconditions euid=%lu page_bytes=%ld mode=%s writeback_cache=0\n",
	       (unsigned long)geteuid(), page, argv[1]);
	if (geteuid() != 0 || page < 4096 || page > 65536 || (page & (page - 1))) {
		fprintf(stderr, "need root and a power-of-two page size in [4096,65536]\n");
		return 2;
	}
	sigemptyset(&action.sa_mask);
	if (sigaction(SIGINT, &action, NULL) || sigaction(SIGTERM, &action, NULL) ||
	    sigaction(SIGHUP, &action, NULL)) {
		perror("sigaction");
		return 2;
	}
	umask(0077);
	for (int which = 0; which < 4 && !interrupted; which++) {
		int rc = run_case(which, direct, page);

		if (rc > result)
			result = rc;
	}
	if (interrupted)
		result = 2;
	printf("summary mode=%s result=%s exit=%d\n", argv[1],
	       result == 0 ? "PASS" : result == 1 ? "REGRESSION" : "ERROR", result);
	return result;
}

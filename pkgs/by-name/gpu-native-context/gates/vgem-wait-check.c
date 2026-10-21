/* SPDX-License-Identifier: MIT
 * Guest-only actual-kernel reservation proof. No GPU commands are submitted.
 * VGEM fences self-expire in the kernel after 10 seconds and are signaled on
 * VGEM file close; userspace release timing is not the containment mechanism.
 * This does not prove renderer or native GPU completion.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <drm.h>
#include <drm_mode.h>
#include <i915_drm.h>
#include <vgem_drm.h>
#include <linux/dma-buf.h>

static int gpu_fd, failures;
static int (*media_ioctl)(int, unsigned long, void *);

static void
check(bool ok, const char *what)
{
   if (!ok) {
      printf("FAIL: %s\n", what);
      failures++;
   }
}

static void
require(bool ok, const char *what)
{
   if (!ok) {
      printf("PREREQUISITE FAILED: %s errno=%d\n", what, errno);
      exit(2);
   }
}

static int64_t
now_ns(void)
{
   struct timespec ts;
   require(clock_gettime(CLOCK_MONOTONIC, &ts) == 0, "monotonic clock");
   return ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void
sleep_ns(long ns)
{
   struct timespec ts = { .tv_nsec = ns };
   while (nanosleep(&ts, &ts) && errno == EINTR)
      ;
}

struct release {
   int fd;
   uint32_t fence;
   pthread_t waiter;
   bool interrupt;
   bool close_file;
   int started;
   int error;
};

static void *
release_fence(void *data)
{
   struct release *release = data;
   if (release->interrupt) {
      sleep_ns(25000000);
      release->error = pthread_kill(release->waiter, SIGUSR1);
      sleep_ns(225000000);
   } else {
      sleep_ns(250000000);
   }
   __atomic_store_n(&release->started, 1, __ATOMIC_SEQ_CST);
   int ret;
   if (release->close_file) {
      ret = close(release->fd);
   } else {
      struct drm_vgem_fence_signal signal = { .fence = release->fence };
      ret = ioctl(release->fd, DRM_IOCTL_VGEM_FENCE_SIGNAL, &signal);
   }
   if (ret)
      release->error = errno;
   return NULL;
}

static void
interrupt_wait(int signo)
{
   (void)signo;
}

/* Each source fence has a private VGEM file owner. Closing that file cancels
 * this proof's fence even when sync_file/destination reservation references live.
 */
static struct release
attach_busy_fence(const char *vgem_node, int target_dmabuf)
{
   int source_fd = open(vgem_node, O_RDWR | O_CLOEXEC);
   require(source_fd >= 0, "open existing VGEM node (no module loading)");
   char name[32] = { 0 };
   struct drm_version version = { .name_len = sizeof(name) - 1, .name = name };
   require(ioctl(source_fd, DRM_IOCTL_VERSION, &version) == 0 &&
           strcmp(name, "vgem") == 0, "source node is actually VGEM");
   struct drm_mode_create_dumb dumb = { .width = 64, .height = 64, .bpp = 8 };
   require(ioctl(source_fd, DRM_IOCTL_MODE_CREATE_DUMB, &dumb) == 0, "VGEM allocation");
   /* A READ fence deliberately catches POLLIN (write-fences-only) mistakes. */
   struct drm_vgem_fence_attach attach = { .handle = dumb.handle, .flags = 0 };
   require(ioctl(source_fd, DRM_IOCTL_VGEM_FENCE_ATTACH, &attach) == 0, "VGEM READ fence");
   struct drm_prime_handle prime = { .handle = dumb.handle, .flags = DRM_CLOEXEC | DRM_RDWR };
   require(ioctl(source_fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime) == 0, "VGEM DMA-BUF export");
   struct dma_buf_export_sync_file export = { .flags = DMA_BUF_SYNC_WRITE, .fd = -1 };
   require(ioctl(prime.fd, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &export) == 0, "VGEM real sync_file export");
   struct dma_buf_import_sync_file import = { .flags = DMA_BUF_SYNC_READ, .fd = export.fd };
   require(ioctl(target_dmabuf, DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &import) == 0,
           "import real fence into actual virtgpu BO reservation");
   require(close(export.fd) == 0 && close(prime.fd) == 0, "release transferred fence export fds");
   struct drm_gem_close close_arg = { .handle = dumb.handle };
   require(ioctl(source_fd, DRM_IOCTL_GEM_CLOSE, &close_arg) == 0, "close VGEM BO handle");
   return (struct release){ .fd = source_fd, .fence = attach.out_fence,
                            .waiter = pthread_self() };
}

int
main(int argc, char **argv)
{
   if (argc != 4) {
      printf("usage: %s /absolute/path/libIntelMediaVirtio.so /dev/dri/renderD128 /dev/dri/cardVGEM\n", argv[0]);
      return 2;
   }
   void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
   if (!library) {
      printf("dlopen: %s\n", dlerror());
      return 2;
   }
   int (*acquire)(int, bool *) = (int (*)(int, bool *))dlsym(library, "mos_i915_virtio_acquire");
   void (*release)(int) = (void (*)(int))dlsym(library, "mos_i915_virtio_release");
   media_ioctl = (int (*)(int, unsigned long, void *))dlsym(library, "mos_i915_virtio_ioctl");
   require(acquire && release && media_ioctl, "actual media facade exports");
   gpu_fd = open(argv[2], O_RDWR | O_CLOEXEC);
   bool set_pat;
   require(gpu_fd >= 0 && acquire(gpu_fd, &set_pat) == 1, "real virtgpu i915 acquisition");
   struct drm_i915_gem_create create = { .size = 4096 };
   require(media_ioctl(gpu_fd, DRM_IOCTL_I915_GEM_CREATE, &create) == 0,
           "real virtgpu BO allocation");
   struct drm_prime_handle prime = { .handle = create.handle, .flags = DRM_CLOEXEC | DRM_RDWR };
   require(media_ioctl(gpu_fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime) == 0,
           "actual destination DMA-BUF export");
   struct sigaction action = { .sa_handler = interrupt_wait };
   sigemptyset(&action.sa_mask);
   require(sigaction(SIGUSR1, &action, NULL) == 0, "non-restarting interrupt handler");

   for (unsigned phase = 0; phase < 4; phase++) {
      struct release source = attach_busy_fence(argv[3], prime.fd);
      struct drm_i915_gem_wait wait = { .bo_handle = create.handle };
      int ret = media_ioctl(gpu_fd, DRM_IOCTL_I915_GEM_WAIT, &wait);
      int error = errno;
      check(ret == -1 && error == ETIME && wait.timeout_ns == 0,
            "NOWAIT observes real READ reservation fence");
      source.interrupt = phase == 2;
      source.close_file = phase == 3;
      pthread_t releaser;
      require(pthread_create(&releaser, NULL, release_fence, &source) == 0,
              "start independent VGEM signal/file-close owner");
      const int64_t requested = phase == 0 ? 20000000 : phase == 1 ? -7 : 1000000000;
      wait.timeout_ns = requested;
      int64_t start = now_ns();
      ret = media_ioctl(gpu_fd, DRM_IOCTL_I915_GEM_WAIT, &wait);
      error = errno;
      int64_t elapsed = now_ns() - start;
      bool release_started = __atomic_load_n(&source.started, __ATOMIC_SEQ_CST);
      if (phase == 0) {
         check(ret == -1 && error == ETIME && wait.timeout_ns == 0 &&
               elapsed >= requested && !release_started,
               "finite busy wait honors its deadline before fence signal");
         struct drm_i915_gem_wait probe = { .bo_handle = create.handle };
         check(media_ioctl(gpu_fd, DRM_IOCTL_I915_GEM_WAIT, &probe) == -1 && errno == ETIME,
               "reservation remains busy after finite timeout");
      } else if (phase == 1) {
         check(ret == 0 && wait.timeout_ns == -7 && release_started,
               "negative infinite wait blocks until real kernel fence signal");
      } else if (phase == 2) {
         check(ret == -1 && error == EINTR && !release_started &&
               wait.timeout_ns > 0 && wait.timeout_ns < 1000000000,
               "interrupted wait preserves EINTR and reduced remaining timeout");
      } else {
         check(ret == 0 && release_started && wait.timeout_ns >= 0 &&
               wait.timeout_ns < 1000000000,
               "VGEM file close cancels live imported reservation fence");
      }
      printf("phase=%u ret=%d errno=%d remaining_ns=%lld elapsed_ns=%lld release_started=%d\n",
             phase, ret, error, (long long)wait.timeout_ns, (long long)elapsed, release_started);
      /* A failed assertion must still drain/release the real software fence. */
      wait.timeout_ns = -1;
      check(media_ioctl(gpu_fd, DRM_IOCTL_I915_GEM_WAIT, &wait) == 0,
            "drain actual reservation fence");
      require(pthread_join(releaser, NULL) == 0, "join fence owner");
      check(source.error == 0, "VGEM signal/close and interrupt operations succeed");
      if (!source.close_file)
         check(close(source.fd) == 0, "close source VGEM file owner");
      wait.timeout_ns = 0;
      check(media_ioctl(gpu_fd, DRM_IOCTL_I915_GEM_WAIT, &wait) == 0,
            "NOWAIT observes drained reservation");
   }
   check(close(prime.fd) == 0, "close destination DMA-BUF");
   struct drm_gem_close close_arg = { .handle = create.handle };
   check(media_ioctl(gpu_fd, DRM_IOCTL_GEM_CLOSE, &close_arg) == 0, "close actual virtgpu BO");
   release(gpu_fd);
   close(gpu_fd);
   dlclose(library);
   puts(failures ? "FAIL: actual kernel reservation waits" :
                   "PASS: actual kernel reservation waits (not GPU execution)");
   return failures ? 1 : 0;
}

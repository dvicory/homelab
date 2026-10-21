/* SPDX-License-Identifier: MIT
 * Real-guest check: uses the built media facade and real virtgpu ioctls.
 * The seccomp stage injects kernel syscall failures, not a fake transport.
 * Kernel errors must survive failed diagnostic writes.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "drm-uapi/drm.h"
#include "drm-uapi/i915_drm.h"
#include "drm-uapi/virtgpu_drm.h"

static int gpu_fd;
static int failures;
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
expect_error(unsigned long cmd, void *arg, int expected, const char *what)
{
   errno = 0;
   int ret = media_ioctl(gpu_fd, cmd, arg);
   int error = errno;
   if (ret != -1 || error != expected) {
      printf("FAIL: %s: ret=%d errno=%d expected=%d\n", what, ret, error, expected);
      failures++;
   }
}

static int
inject_ioctl_errors(void)
{
   struct sock_filter insns[] = {
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_ioctl, 0, 7),
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[1])),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, DRM_IOCTL_VIRTGPU_RESOURCE_CREATE_BLOB, 0, 1),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOMEM),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, DRM_IOCTL_PRIME_HANDLE_TO_FD, 0, 1),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EMFILE),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, DRM_IOCTL_PRIME_FD_TO_HANDLE, 0, 1),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EACCES),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
   };
   struct sock_fprog program = {
      .len = sizeof(insns) / sizeof(insns[0]),
      .filter = insns,
   };
   if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))
      return -1;
   return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program);
}

int
main(int argc, char **argv)
{
   if (argc != 3) {
      printf("usage: %s /absolute/path/libIntelMediaVirtio.so /dev/dri/renderD128\n", argv[0]);
      return 2;
   }
   /* Existing Mesa logging controls make the logger-failure stage deterministic. */
   if (setenv("MESA_LOG", "file", 1) || setenv("MESA_LOG_LEVEL", "debug", 1) ||
       unsetenv("MESA_LOG_FILE") || unsetenv("MESA_LOG_FILE_AUTO")) {
      puts("logger setup failed");
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
   if (!acquire || !release || !media_ioctl) {
      puts("missing media facade exports");
      return 2;
   }
   gpu_fd = open(argv[2], O_RDWR | O_CLOEXEC);
   bool set_pat;
   if (gpu_fd < 0 || acquire(gpu_fd, &set_pat) != 1) {
      printf("real virtgpu i915 acquire failed: errno=%d\n", errno);
      return 2;
   }

   struct drm_i915_gem_create create = { .size = 4096 };
   if (media_ioctl(gpu_fd, DRM_IOCTL_I915_GEM_CREATE, &create)) {
      printf("initial real allocation failed: errno=%d\n", errno);
      release(gpu_fd);
      close(gpu_fd);
      return 2;
   }
   const int64_t timeouts[] = { 0, 100000000, INT64_MAX, -7 };
   for (unsigned i = 0; i < sizeof(timeouts) / sizeof(timeouts[0]); i++) {
      struct drm_i915_gem_wait wait = {
         .bo_handle = create.handle, .timeout_ns = timeouts[i],
      };
      check(media_ioctl(gpu_fd, DRM_IOCTL_I915_GEM_WAIT, &wait) == 0, "idle GEM_WAIT succeeds");
      check(timeouts[i] > 0 ? wait.timeout_ns >= 0 && wait.timeout_ns <= timeouts[i] :
                             wait.timeout_ns == timeouts[i], "GEM_WAIT remaining timeout contract");
   }
   struct drm_i915_gem_wait wait = { .bo_handle = create.handle, .flags = 1 };
   expect_error(DRM_IOCTL_I915_GEM_WAIT, &wait, EINVAL, "GEM_WAIT rejects flags");
   wait = (struct drm_i915_gem_wait){ .bo_handle = 0 };
   expect_error(DRM_IOCTL_I915_GEM_WAIT, &wait, ENOENT, "NOWAIT missing object");
   wait.timeout_ns = 100000000;
   expect_error(DRM_IOCTL_I915_GEM_WAIT, &wait, ENOENT, "finite wait missing object");
   struct drm_prime_handle prime = { .fd = -1 };
   expect_error(DRM_IOCTL_PRIME_FD_TO_HANDLE, &prime, EBADF, "PRIME bad fd errno");
   prime = (struct drm_prime_handle){ .handle = 0, .flags = DRM_CLOEXEC | DRM_RDWR };
   expect_error(DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime, ENOENT, "PRIME missing handle errno");

   /* Failed logging must not replace the original ioctl errno. */
   int readonly = open("/dev/null", O_RDONLY | O_CLOEXEC);
   if (readonly < 0 || dup2(readonly, STDERR_FILENO) < 0 || inject_ioctl_errors()) {
      printf("fault-injection setup failed: errno=%d\n", errno);
      return 2;
   }
   close(readonly);
   struct drm_i915_gem_create failed_create = { .size = 4096 };
   expect_error(DRM_IOCTL_I915_GEM_CREATE, &failed_create, ENOMEM, "CREATE preserves kernel ENOMEM despite failed logging");
   struct drm_i915_gem_create_ext failed_ext = { .size = 4096 };
   expect_error(DRM_IOCTL_I915_GEM_CREATE_EXT, &failed_ext, ENOMEM, "CREATE_EXT preserves kernel ENOMEM");
   prime = (struct drm_prime_handle){ .handle = create.handle, .flags = DRM_CLOEXEC | DRM_RDWR };
   expect_error(DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime, EMFILE, "PRIME export preserves kernel EMFILE");
   prime = (struct drm_prime_handle){ .fd = -1 };
   expect_error(DRM_IOCTL_PRIME_FD_TO_HANDLE, &prime, EACCES, "PRIME import preserves injected EACCES");
   wait = (struct drm_i915_gem_wait){ .bo_handle = create.handle, .timeout_ns = 100000000 };
   expect_error(DRM_IOCTL_I915_GEM_WAIT, &wait, EMFILE, "finite wait preserves export failure");
   check(wait.timeout_ns == 100000000, "export failure does not mutate timeout");
   wait.timeout_ns = 0;
   check(media_ioctl(gpu_fd, DRM_IOCTL_I915_GEM_WAIT, &wait) == 0,
         "NOWAIT needs no temporary PRIME fd");

   struct drm_gem_close gem_close = { .handle = create.handle };
   check(media_ioctl(gpu_fd, DRM_IOCTL_GEM_CLOSE, &gem_close) == 0, "close real allocation");
   release(gpu_fd);
   close(gpu_fd);
   dlclose(library);
   printf("%s: actual facade allocation/PRIME/idle-wait contracts\n", failures ? "FAIL" : "PASS");
   return failures ? 1 : 0;
}

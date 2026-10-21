#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <vpl/mfxdispatcher.h>
#include <vpl/mfxvideo.h>

/* Identity/session gate only. Actual codec work is required separately. */
int main(int argc, char **argv)
{
    int result = 1, fd = -1, initialized = 0, major, minor;
    VADisplay display = NULL;
    mfxLoader loader = NULL;
    mfxSession session = NULL;
    mfxImplDescription *description = NULL;
    mfxIMPL implementation = 0;
    mfxVersion version = {0};
    mfxPlatform platform;
    mfxHDL returned = NULL;
    const char *names[] = {"mfxImplDescription.Impl", "mfxImplDescription.AccelerationMode", "mfxImplDescription.VendorID"};
    mfxU32 values[] = {MFX_IMPL_TYPE_HARDWARE, MFX_ACCEL_MODE_VIA_VAAPI, 0x8086};
#define REQUIRE(condition, call) do { if (!(condition)) { fprintf(stderr, "FAILED: %s\n", call); goto done; } } while (0)
#define MFX(call) do { mfxStatus s = (call); fprintf(stderr, "%s => %d\n", #call, s); REQUIRE(s == MFX_ERR_NONE, #call); } while (0)
    REQUIRE(argc == 2, "usage: onevpl-session /dev/dri/renderD128");
    fd = open(argv[1], O_RDWR | O_CLOEXEC);
    REQUIRE(fd >= 0, "open selected guest render node");
    display = vaGetDisplayDRM(fd);
    REQUIRE(display != NULL, "vaGetDisplayDRM");
    REQUIRE(vaInitialize(display, &major, &minor) == VA_STATUS_SUCCESS, "vaInitialize");
    initialized = 1;
    printf("VA %d.%d vendor=%s node=%s\n", major, minor, vaQueryVendorString(display), argv[1]);
    loader = MFXLoad();
    REQUIRE(loader != NULL, "MFXLoad");
    for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); ++i) {
        mfxConfig config = MFXCreateConfig(loader);
        mfxVariant value = {0};
        REQUIRE(config != NULL, "MFXCreateConfig");
        value.Type = MFX_VARIANT_TYPE_U32;
        value.Data.U32 = values[i];
        MFX(MFXSetConfigFilterProperty(config, (mfxU8 *)names[i], value));
    }
    MFX(MFXEnumImplementations(loader, 0, MFX_IMPLCAPS_IMPLDESCSTRUCTURE, (mfxHDL *)&description));
    REQUIRE(description != NULL, "implementation description");
    REQUIRE(description->Impl == MFX_IMPL_TYPE_HARDWARE && description->AccelerationMode == MFX_ACCEL_MODE_VIA_VAAPI && description->VendorID == 0x8086, "hardware/VAAPI/Intel implementation identity");
    printf("oneVPL name=%s device=%s vendor=%#x API=%u.%u\n", description->ImplName, description->Dev.DeviceID, description->VendorID, description->ApiVersion.Major, description->ApiVersion.Minor);
    MFX(MFXCreateSession(loader, 0, &session));
    MFX(MFXVideoCORE_SetHandle(session, MFX_HANDLE_VA_DISPLAY, display));
    MFX(MFXVideoCORE_GetHandle(session, MFX_HANDLE_VA_DISPLAY, &returned));
    REQUIRE(returned == display, "session bound to selected VA display");
    MFX(MFXQueryIMPL(session, &implementation));
    REQUIRE((implementation & 0x0f) >= MFX_IMPL_HARDWARE && (implementation & 0x0f) <= MFX_IMPL_HARDWARE4 && (implementation & 0x0f) != MFX_IMPL_AUTO_ANY && (implementation & 0x0f) != MFX_IMPL_HARDWARE_ANY, "explicit hardware implementation");
    REQUIRE((implementation & 0xff00) == MFX_IMPL_VIA_VAAPI, "session VAAPI acceleration");
    MFX(MFXQueryVersion(session, &version));
    memset(&platform, 0, sizeof(platform));
    MFX(MFXVideoCORE_QueryPlatform(session, &platform));
    printf("PASS hardware oneVPL session impl=%#x API=%u.%u adapter=%u device=%#x; codec gates still required\n", implementation, version.Major, version.Minor, platform.MediaAdapterType, platform.DeviceId);
    result = 0;
done:
    if (session) { mfxStatus s = MFXClose(session); if (s != MFX_ERR_NONE) result = 1; }
    if (description) { mfxStatus s = MFXDispReleaseImplDescription(loader, description); if (s != MFX_ERR_NONE) result = 1; }
    if (loader) MFXUnload(loader);
    if (initialized && vaTerminate(display) != VA_STATUS_SUCCESS) result = 1;
    if (fd >= 0 && close(fd)) result = 1;
    return result;
}

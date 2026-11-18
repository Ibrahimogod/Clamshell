// Loads ClamshellMicrophone.driver in this process (as coreaudiod would) and checks what the HAL asks of
// it: the factory, the device's properties, the clock, and that output written comes back on the input.
// Run: tools/scripts/test-microphone-driver.sh (no installation, no sudo).
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;
#define CHECK(cond, ...) do { if (cond) { printf("ok   "); } else { printf("FAIL "); failures++; } printf(__VA_ARGS__); printf("\n"); } while (0)

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s path/to/ClamshellMicrophone.driver/Contents/MacOS/ClamshellMicrophone\n", argv[0]); return 2; }
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (lib == NULL) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    void *(*create)(CFAllocatorRef, CFUUIDRef) = (void *(*)(CFAllocatorRef, CFUUIDRef))dlsym(lib, "ClamshellMicrophone_Create");
    CHECK(create != NULL, "factory exported");
    if (create == NULL) return 1;
    AudioServerPlugInDriverRef d = (AudioServerPlugInDriverRef)create(NULL, kAudioServerPlugInTypeUUID);
    CHECK(d != NULL, "factory returns a driver for the AudioServerPlugIn type");
    if (d == NULL) return 1;
    AudioServerPlugInDriverInterface *f = *d;
    void *iface = NULL;
    CHECK(f->QueryInterface(d, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &iface) == S_OK && iface == d, "QueryInterface");
    static AudioServerPlugInHostInterface host;   // the driver only keeps the pointer
    CHECK(f->Initialize(d, &host) == 0, "Initialize");

    AudioObjectPropertyAddress a = { kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef uid = CFSTR("ClamshellMicrophone_UID");
    AudioObjectID dev = 0; UInt32 size = sizeof(dev);
    CHECK(f->GetPropertyData(d, kAudioObjectPlugInObject, 0, &a, sizeof(uid), &uid, size, &size, &dev) == 0 && dev == 2, "UID → device %u", dev);

    a.mSelector = kAudioObjectPropertyName;
    CFStringRef name = NULL; size = sizeof(name);
    CHECK(f->GetPropertyData(d, dev, 0, &a, 0, NULL, size, &size, &name) == 0 && name != NULL
          && CFStringCompare(name, CFSTR("Clamshell Microphone"), 0) == kCFCompareEqualTo, "device name");

    a.mSelector = kAudioDevicePropertyStreams; a.mScope = kAudioObjectPropertyScopeInput;
    CHECK(f->GetPropertyDataSize(d, dev, 0, &a, 0, NULL, &size) == 0 && size == sizeof(AudioObjectID), "one input stream");
    a.mScope = kAudioObjectPropertyScopeGlobal;
    CHECK(f->GetPropertyDataSize(d, dev, 0, &a, 0, NULL, &size) == 0 && size == 2 * sizeof(AudioObjectID), "two streams in all");

    UInt32 canDefault = 9; size = sizeof(canDefault);
    a.mSelector = kAudioDevicePropertyDeviceCanBeDefaultDevice; a.mScope = kAudioObjectPropertyScopeOutput;
    CHECK(f->GetPropertyData(d, dev, 0, &a, 0, NULL, size, &size, &canDefault) == 0 && canDefault == 0, "never the default output");
    a.mScope = kAudioObjectPropertyScopeInput;
    CHECK(f->GetPropertyData(d, dev, 0, &a, 0, NULL, size, &size, &canDefault) == 0 && canDefault == 1, "can be the default input");

    AudioStreamBasicDescription fmt; size = sizeof(fmt);
    a.mSelector = kAudioStreamPropertyVirtualFormat; a.mScope = kAudioObjectPropertyScopeGlobal;
    CHECK(f->GetPropertyData(d, 3, 0, &a, 0, NULL, size, &size, &fmt) == 0 && fmt.mSampleRate == 48000 && fmt.mChannelsPerFrame == 2
          && fmt.mBytesPerFrame == 8, "48 kHz stereo float");
    a.mSelector = 'zzzz';
    CHECK(!f->HasProperty(d, dev, 0, &a), "unknown property is absent");
    a.mSelector = kAudioDevicePropertyNominalSampleRate;
    CHECK(f->HasProperty(d, dev, 0, &a), "has a sample rate");

    CHECK(f->StartIO(d, dev, 1) == 0, "StartIO");
    Float64 t0 = 0, t1 = 0; UInt64 h0 = 0, h1 = 0, seed = 0;
    f->GetZeroTimeStamp(d, dev, 1, &t0, &h0, &seed);
    usleep(700 * 1000);                       // two ring periods (16384 frames ≈ 341 ms each)
    f->GetZeroTimeStamp(d, dev, 1, &t1, &h1, &seed);
    f->GetZeroTimeStamp(d, dev, 1, &t1, &h1, &seed);
    CHECK(t1 > t0 && h1 > h0, "clock advances (%.0f → %.0f)", t0, t1);

    Boolean will = false, inPlace = false;
    f->WillDoIOOperation(d, dev, 1, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace);
    CHECK(will && inPlace, "does WriteMix in place");

    enum { N = 512 };
    Float32 out[N * 2], in[N * 2];
    for (int i = 0; i < N * 2; i++) out[i] = (Float32)(i + 1) / 1024.0f;
    AudioServerPlugInIOCycleInfo cycle; memset(&cycle, 0, sizeof(cycle));
    cycle.mOutputTime.mSampleTime = 100000;
    f->DoIOOperation(d, dev, 4, 1, kAudioServerPlugInIOOperationWriteMix, N, &cycle, out, NULL);
    cycle.mInputTime.mSampleTime = 100000;
    memset(in, 0, sizeof(in));
    f->DoIOOperation(d, dev, 3, 1, kAudioServerPlugInIOOperationReadInput, N, &cycle, in, NULL);
    CHECK(memcmp(in, out, sizeof(in)) == 0, "what plays into the output comes out of the input");
    for (int i = 0; i < N * 2; i++) in[i] = 1;
    f->DoIOOperation(d, dev, 3, 1, kAudioServerPlugInIOOperationReadInput, N, &cycle, in, NULL);
    int silent = 1; for (int i = 0; i < N * 2; i++) if (in[i] != 0) silent = 0;
    CHECK(silent, "read once: silence afterwards, no stale loop");
    CHECK(f->StopIO(d, dev, 1) == 0, "StopIO");

    printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
    return failures ? 1 : 0;
}

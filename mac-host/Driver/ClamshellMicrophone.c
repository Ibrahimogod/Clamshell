// Clamshell Microphone (1.1): a loopback audio device for the phone's microphone on the Mac.
//
// Clamshell Host plays the phone's microphone (decoded Opus) into this device's output; the same samples
// come out of its input, which is what FaceTime, Zoom or QuickTime record from. Nothing else is in it: one
// device, one stereo 48 kHz float input stream, one output stream, a ring buffer between them, and no
// controls. It can't be the default output (so the Mac's sound never disappears into it by accident).
//
// An AudioServerPlugIn runs inside coreaudiod. Install it with tools/scripts/install-microphone.sh (copies
// it to /Library/Audio/Plug-Ins/HAL and restarts coreaudiod; it needs your administrator password, so you
// run it yourself). Structure follows Apple's NullAudio sample driver.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#pragma mark Constants

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_StreamInput = 3,
    kObjectID_StreamOutput = 4,
};

#define kDeviceUID       "ClamshellMicrophone_UID"      // MicPlayer.deviceUID in the host
#define kDeviceModelUID  "ClamshellMicrophone_ModelUID"
#define kDeviceName      "Clamshell Microphone"
#define kManufacturer    "Clamshell"

static const Float64 kSampleRate = 48000.0;
static const UInt32 kChannels = 2;
static const UInt32 kBytesPerFrame = sizeof(Float32) * 2;
// The ring (about 340 ms) and the zero time stamp period. Output lands here at its sample time and is read
// back (then cleared) when the input reaches that sample time, about two IO buffers later.
#define kRingFrames 16384

#pragma mark State

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gIOMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static UInt64 gIOClients = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;
static Float32 gRing[kRingFrames * 2];

#pragma mark Interface

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG AddRef(void *inDriver);
static ULONG Release(void *inDriver);
static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                             const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                 UInt64 inChangeAction, void *inChangeInfo);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                               UInt64 inChangeAction, void *inChangeInfo);
static Boolean HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                           const AudioObjectPropertyAddress *inAddress);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                    const void *inQualifierData, UInt32 *outDataSize);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                  UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                 UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                              UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                              const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                               UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformDeviceConfigurationChange, AbortDeviceConfigurationChange, HasProperty, IsPropertySettable, GetPropertyDataSize,
    GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation,
    EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

/// The factory named in Info.plist (CFPlugInFactories).
void *ClamshellMicrophone_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void *ClamshellMicrophone_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (inRequestedTypeUUID != NULL && CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

#pragma mark IUnknown

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) gRefCount++;
    ULONG n = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return n;
}

static ULONG Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG n = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return n;
}

#pragma mark Basic operations

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    // Host ticks per sample frame: (ns per frame) × (ticks per ns).
    gHostTicksPerFrame = (1e9 / kSampleRate) * ((Float64)tb.denom / (Float64)tb.numer);
    return 0;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) { (void)d; (void)id; return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *c) { (void)d; (void)id; (void)c; return 0; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *c) { (void)d; (void)id; (void)c; return 0; }
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void *i) { (void)d; (void)id; (void)a; (void)i; return 0; }
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void *i) { (void)d; (void)id; (void)a; (void)i; return 0; }

#pragma mark Properties

static AudioStreamBasicDescription Format(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

// One function answers both "how big" (outData NULL) and "what" (outData set), so the two can't disagree.
// Helpers: a scalar, a CFString (retained for the caller), and an array of object IDs.
#define SCALAR(type, value) do { \
        if (outData != NULL) { if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; *(type *)outData = (value); } \
        *outDataSize = sizeof(type); return 0; } while (0)
#define STRING(literal) do { \
        if (outData != NULL) { if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError; \
            *(CFStringRef *)outData = CFSTR(literal); } \
        *outDataSize = sizeof(CFStringRef); return 0; } while (0)

static OSStatus IDs(const AudioObjectID *ids, UInt32 count, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (outData == NULL) { *outDataSize = count * (UInt32)sizeof(AudioObjectID); return 0; }
    UInt32 n = inDataSize / (UInt32)sizeof(AudioObjectID);
    if (n > count) n = count;
    if (n > 0 && ids != NULL) memcpy(outData, ids, n * sizeof(AudioObjectID));
    *outDataSize = n * (UInt32)sizeof(AudioObjectID);
    return 0;
}

static OSStatus Property(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qualSize, const void *qual,
                         UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    const AudioObjectID device[] = { kObjectID_Device };
    const AudioObjectID both[] = { kObjectID_StreamInput, kObjectID_StreamOutput };
    const AudioObjectID input[] = { kObjectID_StreamInput };
    const AudioObjectID output[] = { kObjectID_StreamOutput };
    switch (obj) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: SCALAR(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: SCALAR(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: STRING(kManufacturer);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: return IDs(device, 1, inDataSize, outDataSize, outData);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID found = kAudioObjectUnknown;
            if (outData != NULL && qualSize >= sizeof(CFStringRef) && qual != NULL) {
                CFStringRef uid = *(const CFStringRef *)qual;
                if (uid != NULL && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) found = kObjectID_Device;
            }
            SCALAR(AudioObjectID, found);
        }
        case kAudioPlugInPropertyResourceBundle: STRING("");
        default: return kAudioHardwareUnknownPropertyError;
        }

    case kObjectID_Device: {
        const Boolean isInput = a->mScope == kAudioObjectPropertyScopeInput;
        const Boolean isOutput = a->mScope == kAudioObjectPropertyScopeOutput;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: SCALAR(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: SCALAR(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName: STRING(kDeviceName);
        case kAudioObjectPropertyManufacturer: STRING(kManufacturer);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            if (isInput) return IDs(input, 1, inDataSize, outDataSize, outData);
            if (isOutput) return IDs(output, 1, inDataSize, outDataSize, outData);
            return IDs(both, 2, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyControlList: return IDs(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyDeviceUID: STRING(kDeviceUID);
        case kAudioDevicePropertyModelUID: STRING(kDeviceModelUID);
        case kAudioDevicePropertyTransportType: SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: return IDs(device, 1, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyClockDomain: SCALAR(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: SCALAR(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIOClients > 0 ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            SCALAR(UInt32, running);
        }
        // A microphone, never a speaker: only the input side can be a default device.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: SCALAR(UInt32, isInput ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: SCALAR(UInt32, 0);
        case kAudioDevicePropertyLatency: SCALAR(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: SCALAR(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: SCALAR(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            SCALAR(AudioValueRange, r);
        }
        case kAudioDevicePropertyIsHidden: SCALAR(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: SCALAR(UInt32, kRingFrames);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            const UInt32 size = 2 * sizeof(UInt32);
            if (outData != NULL) {
                if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
                ((UInt32 *)outData)[0] = 1;
                ((UInt32 *)outData)[1] = 2;
            }
            *outDataSize = size;
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            const UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
            if (outData != NULL) {
                if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout *l = (AudioChannelLayout *)outData;
                memset(l, 0, size);
                l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                l->mNumberChannelDescriptions = kChannels;
                l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            }
            *outDataSize = size;
            return 0;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    case kObjectID_StreamInput:
    case kObjectID_StreamOutput: {
        const Boolean isInput = obj == kObjectID_StreamInput;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: SCALAR(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: SCALAR(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: return IDs(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioStreamPropertyIsActive: SCALAR(UInt32, 1);
        case kAudioStreamPropertyDirection: SCALAR(UInt32, isInput ? 1 : 0);
        case kAudioStreamPropertyTerminalType: SCALAR(UInt32, isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: SCALAR(UInt32, 1);
        case kAudioStreamPropertyLatency: SCALAR(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: SCALAR(AudioStreamBasicDescription, Format());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r;
            r.mFormat = Format();
            r.mSampleRateRange.mMinimum = kSampleRate;
            r.mSampleRateRange.mMaximum = kSampleRate;
            SCALAR(AudioStreamRangedDescription, r);
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    default:
        return kAudioHardwareBadObjectError;
    }
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)pid;
    if (d != gDriverRef || a == NULL) return false;
    UInt32 size = 0;
    return Property(obj, a, 0, NULL, UINT32_MAX, &size, NULL) == 0;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    (void)pid;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (a == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    UInt32 size = 0;
    OSStatus s = Property(obj, a, 0, NULL, UINT32_MAX, &size, NULL);
    if (s != 0) return s;
    *out = false;              // one fixed format, no controls
    return 0;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                    UInt32 qualSize, const void *qual, UInt32 *outSize) {
    (void)pid;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (a == NULL || outSize == NULL) return kAudioHardwareIllegalOperationError;
    return Property(obj, a, qualSize, qual, UINT32_MAX, outSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qualSize, const void *qual, UInt32 inDataSize, UInt32 *outSize, void *outData) {
    (void)pid;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (a == NULL || outSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    return Property(obj, a, qualSize, qual, inDataSize, outSize, outData);
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qualSize, const void *qual, UInt32 inDataSize, const void *inData) {
    (void)pid; (void)qualSize; (void)qual;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (a == NULL) return kAudioHardwareIllegalOperationError;
    // Setting the format or rate it already has is fine; anything else isn't offered.
    if ((obj == kObjectID_StreamInput || obj == kObjectID_StreamOutput)
        && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inData == NULL || inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *f = (const AudioStreamBasicDescription *)inData;
        AudioStreamBasicDescription ours = Format();
        return f->mSampleRate == ours.mSampleRate && f->mFormatID == ours.mFormatID && f->mChannelsPerFrame == ours.mChannelsPerFrame
                   && f->mBitsPerChannel == ours.mBitsPerChannel ? 0 : kAudioDeviceUnsupportedFormatError;
    }
    if (obj == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inData == NULL || inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64 *)inData == kSampleRate ? 0 : kAudioHardwareIllegalOperationError;
    }
    return kAudioHardwareUnknownPropertyError;
}

#pragma mark IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOClients == 0) {
        pthread_mutex_lock(&gIOMutex);
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        memset(gRing, 0, sizeof(gRing));
        pthread_mutex_unlock(&gIOMutex);
    }
    gIOClients++;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOClients > 0) gIOClients--;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

// A virtual clock that runs at exactly 48 kHz on the host's clock: one time stamp per ring period.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gIOMutex);
    const Float64 ticksPerRing = gHostTicksPerFrame * kRingFrames;
    const UInt64 now = mach_absolute_time();
    const UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * ticksPerRing);
    if (next <= now) gNumberTimeStamps++;
    *outSampleTime = (Float64)gNumberTimeStamps * kRingFrames;
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerRing);
    *outSeed = 1;
    pthread_mutex_unlock(&gIOMutex);
    return 0;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op,
                                  Boolean *outWillDo, Boolean *outInPlace) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    const Boolean yes = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo != NULL) *outWillDo = yes;
    if (outInPlace != NULL) *outInPlace = true;
    return 0;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames,
                                 const AudioServerPlugInIOCycleInfo *info) {
    (void)client; (void)op; (void)frames; (void)info;
    return d == gDriverRef && dev == kObjectID_Device ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames,
                               const AudioServerPlugInIOCycleInfo *info) {
    (void)client; (void)op; (void)frames; (void)info;
    return d == gDriverRef && dev == kObjectID_Device ? 0 : kAudioHardwareBadObjectError;
}

static UInt64 RingIndex(Float64 sampleTime) {
    if (sampleTime < 0) return 0;
    return (UInt64)sampleTime % kRingFrames;
}

// Output (what Clamshell Host plays) is written at its sample time; input reads that time back and clears
// it, so the input is silence whenever nothing is playing (no stale loop).
static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client, UInt32 op,
                              UInt32 frames, const AudioServerPlugInIOCycleInfo *info, void *main, void *secondary) {
    (void)client; (void)secondary;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (info == NULL || main == NULL || frames > kRingFrames) return 0;
    Float32 *buf = (Float32 *)main;
    if (op == kAudioServerPlugInIOOperationWriteMix && stream == kObjectID_StreamOutput) {
        UInt64 at = RingIndex(info->mOutputTime.mSampleTime);
        for (UInt32 i = 0; i < frames; i++) {
            UInt64 r = (at + i) % kRingFrames;
            gRing[r * 2] = buf[i * 2];
            gRing[r * 2 + 1] = buf[i * 2 + 1];
        }
    } else if (op == kAudioServerPlugInIOOperationReadInput && stream == kObjectID_StreamInput) {
        UInt64 at = RingIndex(info->mInputTime.mSampleTime);
        for (UInt32 i = 0; i < frames; i++) {
            UInt64 r = (at + i) % kRingFrames;
            buf[i * 2] = gRing[r * 2];
            buf[i * 2 + 1] = gRing[r * 2 + 1];
            gRing[r * 2] = 0;
            gRing[r * 2 + 1] = 0;
        }
    }
    return 0;
}

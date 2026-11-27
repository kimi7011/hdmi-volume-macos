#include <CoreAudio/AudioHardwareBase.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

typedef void *(*DriverFactory)(CFAllocatorRef, CFUUIDRef);

static AudioObjectPropertyAddress Property(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress) {
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
}

static void Read(AudioServerPlugInDriverRef driver, AudioObjectID object, AudioObjectPropertySelector selector,
                 UInt32 size, void *buffer) {
    AudioObjectPropertyAddress address = Property(selector);
    UInt32 written = 0;
    assert((*driver)->GetPropertyData(driver, object, 0, &address, 0, NULL, size, &written, buffer) == noErr);
    assert(size == written);
}

int main(int argc, const char **argv) {
    assert(argc == 2);
    const char *path = argv[1];
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), true);
    assert(url != NULL);
    CFBundleRef bundle = CFBundleCreate(NULL, url);
    assert(bundle != NULL);
    DriverFactory factory = (DriverFactory)CFBundleGetFunctionPointerForName(bundle, CFSTR("HDMIVolume_Create"));
    assert(factory != NULL);
    AudioServerPlugInDriverRef driver = factory(NULL, kAudioServerPlugInTypeUUID);
    assert(driver != NULL && *driver != NULL);
    assert(driver == factory(NULL, kAudioServerPlugInTypeUUID));

    AudioObjectID device = kAudioObjectUnknown;
    Read(driver, kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, sizeof(device), &device);
    assert(device != kAudioObjectUnknown);

    AudioObjectPropertyAddress address = Property(kAudioDevicePropertyDeviceUID);
    assert((*driver)->HasProperty(driver, device, 0, &address));
    CFStringRef uid = NULL;
    Read(driver, device, kAudioDevicePropertyDeviceUID, sizeof(uid), &uid);
    assert(CFEqual(uid, CFSTR("HDMIVolumeDevice")));
    CFRelease(uid);
    address = Property(kAudioObjectPropertyCustomPropertyInfoList);
    assert(!(*driver)->HasProperty(driver, device, 0, &address));

    AudioObjectID controls[3] = {0};
    Read(driver, device, kAudioObjectPropertyControlList, sizeof(controls), controls);
    AudioObjectID volume = kAudioObjectUnknown;
    AudioObjectID mute = kAudioObjectUnknown;
    for (size_t index = 0; index < 3; index++) {
        AudioClassID classID = 0;
        Read(driver, controls[index], kAudioObjectPropertyClass, sizeof(classID), &classID);
        if (classID == kAudioVolumeControlClassID) { volume = controls[index]; }
        if (classID == kAudioMuteControlClassID) { mute = controls[index]; }
    }
    assert(volume && mute);
    Float32 scalar = 0.5f;
    address = Property(kAudioLevelControlPropertyScalarValue);
    assert((*driver)->SetPropertyData(driver, volume, 0, &address, 0, NULL, sizeof(scalar), &scalar) == noErr);
    scalar = NAN;
    Read(driver, volume, kAudioLevelControlPropertyScalarValue, sizeof(scalar), &scalar);
    assert(fabsf(scalar - 0.5f) < 0.001f);
    Read(driver, volume, kAudioLevelControlPropertyConvertScalarToDecibels, sizeof(scalar), &scalar);
    assert(fabsf(scalar - (-48.0f)) < 0.001f);
    Read(driver, volume, kAudioLevelControlPropertyConvertDecibelsToScalar, sizeof(scalar), &scalar);
    assert(fabsf(scalar - 0.5f) < 0.001f);

    UInt32 muted = 1;
    address = Property(kAudioBooleanControlPropertyValue);
    assert((*driver)->SetPropertyData(driver, mute, 0, &address, 0, NULL, sizeof(muted), &muted) == noErr);
    muted = 0;
    Read(driver, mute, kAudioBooleanControlPropertyValue, sizeof(muted), &muted);
    assert(muted == 1);

    assert((*driver)->StartIO(driver, device, 1) == noErr);
    assert((*driver)->StartIO(driver, device, 2) == noErr);
    assert((*driver)->StopIO(driver, device, 1) == noErr);
    UInt32 running = 0;
    Read(driver, device, kAudioDevicePropertyDeviceIsRunning, sizeof(running), &running);
    assert(running == 1);
    assert((*driver)->StopIO(driver, device, 2) == noErr);
    Read(driver, device, kAudioDevicePropertyDeviceIsRunning, sizeof(running), &running);
    assert(running == 0);

    CFRelease(bundle);
    CFRelease(url);
    puts("Driver factory, device properties, volume, mute and I/O lifecycle passed.");
    return 0;
}

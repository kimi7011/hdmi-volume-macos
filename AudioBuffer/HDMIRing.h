#ifndef HDMI_RING_H
#define HDMI_RING_H

#include <stdint.h>

typedef struct HDMIRing HDMIRing;
typedef struct HDMIAppMixer HDMIAppMixer;

typedef struct {
    uint64_t inputFrames;
    uint64_t renderedFrames;
    uint64_t silenceFrames;
    uint64_t droppedFrames;
    uint32_t bufferedFrames;
    float inputPeak;
    float outputPeak;
} HDMIRingStats;

typedef struct {
    const float *left;
    const float *right;
    uint32_t frames;
    uint32_t stride;
} HDMIRingMixerInput;

typedef struct {
    float inputPeak;
    float mixedPeak;
} HDMIRingAppStats;

// Create and destroy on the control thread with both audio callbacks stopped.
// Rates are in Hz. A new ring starts at unity gain, with a short fade-in.
HDMIRing *HDMIRingCreate(double captureRate, double outputRate);
void HDMIRingDestroy(HDMIRing *ring);

// One capture callback may write at a time. A null right channel means mono.
// The return value counts input frames accepted into the ring.
uint32_t HDMIRingWritePlanar(HDMIRing *ring, const float *left,
                             const float *right, uint32_t frames);
uint32_t HDMIRingWriteInterleaved(HDMIRing *ring, const float *samples,
                                  uint32_t frames, uint32_t channels);

// A mixer belongs to one capture topology. Create it on the control thread.
// Set initial gains before starting capture, and destroy it after stopping
// capture. App indices are stable and zero-based within this mixer.
HDMIAppMixer *HDMIAppMixerCreate(double captureRate, uint32_t appCount);
void HDMIAppMixerDestroy(HDMIAppMixer *mixer);
void HDMIAppMixerSetInitialGain(HDMIAppMixer *mixer, uint32_t appIndex, float gain);

// Buses start at the same capture timestamp. The remainder is always unity.
// Stride is 1 for planar/mono or 2 for interleaved stereo (right points one
// sample after left). A missing left channel or exhausted input is silent.
// A missing right channel means mono. Each app view belongs to its fixed index.
uint32_t HDMIRingWriteMix(HDMIRing *ring, HDMIAppMixer *mixer, HDMIRingMixerInput remainder,
                          const HDMIRingMixerInput *apps, uint32_t appCount);

// Only one output callback may read at a time. Unavailable frames are zeroed.
// A null right channel yields a mono downmix. The return value counts audio
// frames rendered, excluding silence inserted during a buffer underrun.
uint32_t HDMIRingReadPlanar(HDMIRing *ring, float *left, float *right,
                            uint32_t frames);

// These functions may run on the control thread during playback.
// Gain is linear, 0 through 1. Reported peaks are from the latest callbacks.
void HDMIRingSetGain(HDMIRing *ring, float gain);
void HDMIRingGetStats(const HDMIRing *ring, HDMIRingStats *stats);
void HDMIAppMixerSetGain(HDMIAppMixer *mixer, uint32_t appIndex, float gain);
void HDMIAppMixerGetStats(const HDMIAppMixer *mixer, uint32_t appIndex, HDMIRingAppStats *stats);
float HDMIAppMixerGetRemainderPeak(const HDMIAppMixer *mixer);

#endif

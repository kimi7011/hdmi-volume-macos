#include "HDMIRing.h"

#include <math.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

enum { ringCapacity = 65536, ringMask = ringCapacity - 1 };

typedef struct {
    float left;
    float right;
} StereoFrame;

typedef struct {
    _Atomic float targetGain;
    _Atomic float inputPeak;
    _Atomic float mixedPeak;
    float currentGain;
} AppBus;

struct HDMIAppMixer {
    _Atomic float remainderInputPeak;
    uint32_t appCount;
    float gainIncrement;
    AppBus apps[];
};

struct HDMIRing {
    _Atomic uint64_t writeFrame;
    _Atomic uint64_t readFrame;
    _Atomic float targetGain;
    _Atomic uint64_t inputFrames;
    _Atomic uint64_t renderedFrames;
    _Atomic uint64_t silenceFrames;
    _Atomic uint64_t droppedFrames;
    _Atomic float inputPeak;
    _Atomic float outputPeak;

    double nominalStep;
    double targetFill;
    double correction;
    double fraction;
    double outputRate;
    float currentGain;
    float gainIncrement;
    bool primed;
    StereoFrame frames[ringCapacity];
};

HDMIRing *HDMIRingCreate(double captureRate, double outputRate) {
    if (!isfinite(captureRate) || !isfinite(outputRate) ||
        captureRate < 8000 || captureRate > 384000 ||
        outputRate < 8000 || outputRate > 384000) {
        return NULL;
    }

    HDMIRing *ring = calloc(1, sizeof(*ring));
    if (ring == NULL) return NULL;

    atomic_init(&ring->writeFrame, 0);
    atomic_init(&ring->readFrame, 0);
    atomic_init(&ring->targetGain, 1);
    atomic_init(&ring->inputFrames, 0);
    atomic_init(&ring->renderedFrames, 0);
    atomic_init(&ring->silenceFrames, 0);
    atomic_init(&ring->droppedFrames, 0);
    atomic_init(&ring->inputPeak, 0);
    atomic_init(&ring->outputPeak, 0);
    if (!atomic_is_lock_free(&ring->writeFrame) ||
        !atomic_is_lock_free(&ring->targetGain)) {
        free(ring);
        return NULL;
    }
    ring->nominalStep = captureRate / outputRate;
    ring->targetFill = captureRate * 0.025;
    ring->outputRate = outputRate;
    ring->gainIncrement = (float)(1 / (outputRate * 0.005));
    return ring;
}

void HDMIRingDestroy(HDMIRing *ring) {
    free(ring);
}

HDMIAppMixer *HDMIAppMixerCreate(double captureRate, uint32_t appCount) {
    if (!isfinite(captureRate) || captureRate < 8000 || captureRate > 384000) return NULL;

    size_t count = appCount;
    if (count > (SIZE_MAX - sizeof(HDMIAppMixer)) / sizeof(AppBus)) return NULL;
    HDMIAppMixer *mixer = calloc(1, sizeof(*mixer) + count * sizeof(AppBus));
    if (mixer == NULL) return NULL;
    atomic_init(&mixer->remainderInputPeak, 0);
    if (!atomic_is_lock_free(&mixer->remainderInputPeak)) {
        free(mixer);
        return NULL;
    }
    mixer->appCount = appCount;
    mixer->gainIncrement = (float)(1 / (captureRate * 0.005));
    for (uint32_t index = 0; index < appCount; ++index) {
        AppBus *bus = &mixer->apps[index];
        atomic_init(&bus->targetGain, 1);
        atomic_init(&bus->inputPeak, 0);
        atomic_init(&bus->mixedPeak, 0);
        bus->currentGain = 1;
    }
    return mixer;
}

void HDMIAppMixerDestroy(HDMIAppMixer *mixer) {
    free(mixer);
}

static uint32_t availableWriteFrames(const HDMIRing *ring, uint64_t write, uint32_t frames) {
    uint64_t read = atomic_load_explicit(&ring->readFrame, memory_order_acquire);
    uint32_t writable = ringCapacity - (uint32_t)(write - read);
    return frames < writable ? frames : writable;
}

static void publishWrite(HDMIRing *ring, uint64_t write, uint32_t accepted,
                         uint32_t frames, float peak) {
    atomic_store_explicit(&ring->writeFrame, write + accepted, memory_order_release);
    atomic_fetch_add_explicit(&ring->inputFrames, accepted, memory_order_relaxed);
    atomic_fetch_add_explicit(&ring->droppedFrames, frames - accepted, memory_order_relaxed);
    atomic_store_explicit(&ring->inputPeak, peak, memory_order_relaxed);
}

static float framePeak(StereoFrame frame) {
    return fmaxf(fabsf(frame.left), fabsf(frame.right));
}

static uint32_t writeFrames(HDMIRing *ring, const float *left,
                            const float *right, uint32_t stride,
                            uint32_t frames) {
    if (ring == NULL || left == NULL || frames == 0) return 0;

    uint64_t write = atomic_load_explicit(&ring->writeFrame, memory_order_relaxed);
    uint32_t accepted = availableWriteFrames(ring, write, frames);
    float peak = 0;
    for (uint32_t index = 0; index < accepted; ++index) {
        size_t offset = (size_t)index * stride;
        float leftSample = left[offset];
        float rightSample = right == NULL ? leftSample : right[offset];
        StereoFrame frame = {leftSample, rightSample};
        ring->frames[(write + index) & ringMask] = frame;
        peak = fmaxf(peak, framePeak(frame));
    }
    publishWrite(ring, write, accepted, frames, peak);
    return accepted;
}

uint32_t HDMIRingWritePlanar(HDMIRing *ring, const float *left,
                             const float *right, uint32_t frames) {
    return writeFrames(ring, left, right, 1, frames);
}

uint32_t HDMIRingWriteInterleaved(HDMIRing *ring, const float *samples,
                                  uint32_t frames, uint32_t channels) {
    if (samples == NULL || (channels != 1 && channels != 2)) return 0;
    const float *right = channels == 2 ? samples + 1 : NULL;
    return writeFrames(ring, samples, right, channels, frames);
}

static StereoFrame busFrame(HDMIRingMixerInput input, uint32_t index) {
    if (input.left == NULL || index >= input.frames || (input.stride != 1 && input.stride != 2)) {
        return (StereoFrame){0, 0};
    }
    size_t offset = (size_t)index * input.stride;
    float left = input.left[offset];
    return (StereoFrame){left, input.right == NULL ? left : input.right[offset]};
}

static float approachGain(float gain, float target, float increment) {
    return gain + fmaxf(-increment, fminf(increment, target - gain));
}

uint32_t HDMIRingWriteMix(HDMIRing *ring, HDMIAppMixer *mixer, HDMIRingMixerInput remainder,
                          const HDMIRingMixerInput *apps, uint32_t appCount) {
    if (ring == NULL || mixer == NULL || appCount != mixer->appCount ||
        (appCount != 0 && apps == NULL)) return 0;
    uint32_t frames = remainder.frames;
    for (uint32_t index = 0; index < appCount; ++index) {
        if (apps[index].frames > frames) frames = apps[index].frames;
    }
    if (frames == 0) return 0;

    uint64_t write = atomic_load_explicit(&ring->writeFrame, memory_order_relaxed);
    uint32_t accepted = availableWriteFrames(ring, write, frames);
    float remainderPeak = 0;
    for (uint32_t index = 0; index < accepted; ++index) {
        StereoFrame frame = busFrame(remainder, index);
        ring->frames[(write + index) & ringMask] = frame;
        remainderPeak = fmaxf(remainderPeak, framePeak(frame));
    }
    atomic_store_explicit(&mixer->remainderInputPeak, remainderPeak, memory_order_relaxed);

    for (uint32_t app = 0; app < appCount; ++app) {
        const HDMIRingMixerInput input = apps[app];
        AppBus *bus = &mixer->apps[app];
        float inputPeak = 0;
        float mixedPeak = 0;
        float gain = bus->currentGain;
        float target = atomic_load_explicit(&bus->targetGain, memory_order_relaxed);
        uint32_t usable = input.frames < accepted ? input.frames : accepted;
        if (input.left == NULL || (input.stride != 1 && input.stride != 2)) usable = 0;
        for (uint32_t index = 0; index < usable; ++index) {
            gain = approachGain(gain, target, mixer->gainIncrement);
            StereoFrame frame = busFrame(input, index);
            float magnitude = framePeak(frame);
            inputPeak = fmaxf(inputPeak, magnitude);
            mixedPeak = fmaxf(mixedPeak, magnitude * gain);
            StereoFrame *mixed = &ring->frames[(write + index) & ringMask];
            mixed->left += frame.left * gain;
            mixed->right += frame.right * gain;
        }
        bus->currentGain = approachGain(gain, target, mixer->gainIncrement * (accepted - usable));
        atomic_store_explicit(&bus->inputPeak, inputPeak, memory_order_relaxed);
        atomic_store_explicit(&bus->mixedPeak, mixedPeak, memory_order_relaxed);
    }

    float peak = 0;
    for (uint32_t index = 0; index < accepted; ++index) {
        peak = fmaxf(peak, framePeak(ring->frames[(write + index) & ringMask]));
    }
    publishWrite(ring, write, accepted, frames, peak);
    return accepted;
}

uint32_t HDMIRingReadPlanar(HDMIRing *ring, float *left, float *right,
                            uint32_t frames) {
    if (left == NULL || frames == 0) return 0;

    uint32_t rendered = 0;
    float peak = 0;
    if (ring != NULL) {
        uint64_t read = atomic_load_explicit(&ring->readFrame, memory_order_relaxed);
        uint64_t write = atomic_load_explicit(&ring->writeFrame, memory_order_acquire);

        // Device callbacks need not be the same size. Leave the target delay
        // buffered after consuming this callback, including at first playback.
        double desired = fmin(ringCapacity * 0.75,
                              ring->targetFill + frames * ring->nominalStep);
        double available = (double)(write - read);
        if (available > fmax(desired * 3, desired + ring->targetFill * 4)) {
            // A stalled output would otherwise resume with stale audio.
            uint64_t skip = (uint64_t)(available - desired);
            read += skip;
            available -= (double)skip;
            ring->fraction = 0;
            ring->correction = 0;
            ring->currentGain = 0;
            atomic_fetch_add_explicit(&ring->droppedFrames, skip, memory_order_relaxed);
        }

        ring->primed = ring->primed || available >= desired;
        if (ring->primed) {
            // Smooth the occupancy signal because capture and playback can
            // run in either order within a hardware callback period.
            double error = (available - desired) / ring->targetFill;
            double correction = fmax(-0.005, fmin(0.005, error * 0.003));
            double smoothing = fmin(1, (double)frames / (ring->outputRate * 0.3));
            ring->correction += (correction - ring->correction) * smoothing;
            double step = ring->nominalStep * (1 + ring->correction);
            double fraction = ring->fraction;
            float gain = ring->currentGain;
            float targetGain = atomic_load_explicit(&ring->targetGain, memory_order_relaxed);
            while (rendered < frames && write - read >= 2) {
                StereoFrame first = ring->frames[read & ringMask];
                StereoFrame second = ring->frames[(read + 1) & ringMask];
                float lerp = (float) fraction;
                gain = approachGain(gain, targetGain, ring->gainIncrement);
                float leftSample = (first.left + (second.left - first.left) * lerp) * gain;
                float rightSample = (first.right + (second.right - first.right) * lerp) * gain;
                if (right != NULL) {
                    left[rendered] = leftSample;
                    right[rendered] = rightSample;
                    peak = fmaxf(peak, fmaxf(fabsf(leftSample), fabsf(rightSample)));
                } else {
                    float mono = (leftSample + rightSample) * 0.5f;
                    left[rendered] = mono;
                    peak = fmaxf(peak, fabsf(mono));
                }
                ++rendered;
                fraction += step;
                uint32_t advance = (uint32_t)fraction;
                uint64_t remaining = write - read;
                if (advance >= remaining) {
                    read = write;
                    fraction = 0;
                } else {
                    read += advance;
                    fraction -= advance;
                }
            }
            ring->fraction = fraction;
            ring->currentGain = gain;
            if (rendered < frames) {
                ring->primed = false;
                ring->fraction = 0;
                ring->correction = 0;
                ring->currentGain = 0;
            }
        }

        atomic_store_explicit(&ring->readFrame, read, memory_order_release);
        atomic_fetch_add_explicit(&ring->renderedFrames, rendered, memory_order_relaxed);
        atomic_fetch_add_explicit(&ring->silenceFrames, frames - rendered, memory_order_relaxed);
        atomic_store_explicit(&ring->outputPeak, peak, memory_order_relaxed);
    }

    if (rendered < frames) {
        size_t zeroBytes = (size_t)(frames - rendered) * sizeof(*left);
        memset(left + rendered, 0, zeroBytes);
        if (right != NULL) memset(right + rendered, 0, zeroBytes);
    }
    return rendered;
}

static float clampedGain(float gain) {
    return isfinite(gain) ? fmaxf(0, fminf(1, gain)) : 0;
}

void HDMIRingSetGain(HDMIRing *ring, float gain) {
    if (ring == NULL) return;
    atomic_store_explicit(&ring->targetGain, clampedGain(gain), memory_order_relaxed);
}

void HDMIAppMixerSetInitialGain(HDMIAppMixer *mixer, uint32_t appIndex, float gain) {
    if (mixer == NULL || appIndex >= mixer->appCount) return;
    AppBus *bus = &mixer->apps[appIndex];
    bus->currentGain = clampedGain(gain);
    atomic_store_explicit(&bus->targetGain, bus->currentGain, memory_order_relaxed);
}

void HDMIAppMixerSetGain(HDMIAppMixer *mixer, uint32_t appIndex, float gain) {
    if (mixer == NULL || appIndex >= mixer->appCount) return;
    atomic_store_explicit(&mixer->apps[appIndex].targetGain, clampedGain(gain), memory_order_relaxed);
}

void HDMIAppMixerGetStats(const HDMIAppMixer *mixer, uint32_t appIndex, HDMIRingAppStats *stats) {
    if (stats == NULL) return;
    *stats = (HDMIRingAppStats){0};
    if (mixer == NULL || appIndex >= mixer->appCount) return;
    stats->inputPeak = atomic_load_explicit(&mixer->apps[appIndex].inputPeak, memory_order_relaxed);
    stats->mixedPeak = atomic_load_explicit(&mixer->apps[appIndex].mixedPeak, memory_order_relaxed);
}

float HDMIAppMixerGetRemainderPeak(const HDMIAppMixer *mixer) {
    if (mixer == NULL) return 0;
    return atomic_load_explicit(&mixer->remainderInputPeak, memory_order_relaxed);
}

void HDMIRingGetStats(const HDMIRing *ring, HDMIRingStats *stats) {
    if (stats == NULL) return;
    *stats = (HDMIRingStats){0};
    if (ring == NULL) return;
    stats->inputFrames = atomic_load_explicit(&ring->inputFrames, memory_order_relaxed);
    stats->renderedFrames = atomic_load_explicit(&ring->renderedFrames, memory_order_relaxed);
    stats->silenceFrames = atomic_load_explicit(&ring->silenceFrames, memory_order_relaxed);
    stats->droppedFrames = atomic_load_explicit(&ring->droppedFrames, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->readFrame, memory_order_acquire);
    uint64_t write = atomic_load_explicit(&ring->writeFrame, memory_order_acquire);
    uint64_t buffered = write - read;
    stats->bufferedFrames = buffered > ringCapacity ? ringCapacity : (uint32_t)buffered;
    stats->inputPeak = atomic_load_explicit(&ring->inputPeak, memory_order_relaxed);
    stats->outputPeak = atomic_load_explicit(&ring->outputPeak, memory_order_relaxed);
}

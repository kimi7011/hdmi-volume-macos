#include "HDMIRing.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

enum { blockSize = 256 };

static void checkNear(float actual, float expected) {
    assert(fabsf(actual - expected) < 0.0001f);
}

static void fillStereo(float *samples, uint32_t frames) {
    for (uint32_t index = 0; index < frames; ++index) {
        samples[index * 2] = 0.25f;
        samples[index * 2 + 1] = -0.5f;
    }
}

static void testGainAndUnderrun(void) {
    HDMIRing *ring = HDMIRingCreate(48000, 48000);
    assert(ring != NULL);
    float input[blockSize * 2];
    float left[blockSize];
    float right[blockSize];
    fillStereo(input, blockSize);

    assert(HDMIRingReadPlanar(ring, left, right, blockSize) == 0);
    for (int frame = 0; frame < blockSize; ++frame) {
        assert(left[frame] == 0 && right[frame] == 0);
    }
    for (int block = 0; block < 6; ++block) {
        assert(HDMIRingWriteInterleaved(ring, input, blockSize, 2) == blockSize);
    }
    assert(HDMIRingReadPlanar(ring, left, right, blockSize) == blockSize);
    checkNear(left[blockSize - 1], 0.25f);
    checkNear(right[blockSize - 1], -0.5f);

    HDMIRingSetGain(ring, 0.5f);
    assert(HDMIRingWriteInterleaved(ring, input, blockSize, 2) == blockSize);
    assert(HDMIRingReadPlanar(ring, left, right, blockSize) == blockSize);
    checkNear(left[blockSize - 1], 0.125f);
    checkNear(right[blockSize - 1], -0.25f);
    assert(HDMIRingReadPlanar(ring, left, right, blockSize) == blockSize);
    HDMIRingStats stats;
    HDMIRingGetStats(ring, &stats);
    checkNear(stats.inputPeak, 0.5f);
    checkNear(stats.outputPeak, 0.25f);

    HDMIRingSetGain(ring, 0);
    assert(HDMIRingReadPlanar(ring, left, right, blockSize) == blockSize);
    assert(HDMIRingReadPlanar(ring, left, right, blockSize) == blockSize);
    for (int frame = 0; frame < blockSize; ++frame) {
        assert(left[frame] == 0 && right[frame] == 0);
    }
    for (int block = 0; block < 5; ++block) {
        HDMIRingReadPlanar(ring, left, right, blockSize);
    }
    HDMIRingGetStats(ring, &stats);
    assert(stats.silenceFrames > blockSize);
    assert(stats.outputPeak == 0);

    HDMIRingSetGain(ring, 1);
    float mono[blockSize];
    for (int frame = 0; frame < blockSize; ++frame) mono[frame] = 0.3f;
    for (int block = 0; block < 6; ++block) {
        assert(HDMIRingWritePlanar(ring, mono, NULL, blockSize) == blockSize);
    }
    assert(HDMIRingReadPlanar(ring, left, right, blockSize) == blockSize);
    checkNear(left[blockSize - 1], 0.3f);
    checkNear(right[blockSize - 1], 0.3f);
    HDMIRingDestroy(ring);
}

static void testClockDrift(double actualCaptureRate) {
    const double outputRate = 44100;
    HDMIRing *ring = HDMIRingCreate(48000, outputRate);
    assert(ring != NULL);
    float samples[blockSize * 4];
    float left[blockSize];
    float right[blockSize];
    fillStereo(samples, blockSize * 2);
    uint64_t produced = 0;
    const uint32_t blocks = 10000;

    for (uint32_t block = 1; block <= blocks; ++block) {
        double duration = (double)block * blockSize / outputRate;
        uint64_t required = (uint64_t)(duration * actualCaptureRate);
        uint32_t frames = (uint32_t)(required - produced);
        assert(frames < blockSize * 2);
        assert(HDMIRingWriteInterleaved(ring, samples, frames, 2) == frames);
        produced = required;
        uint32_t rendered = HDMIRingReadPlanar(ring, left, right, blockSize);
        if (block > 10) {
            assert(rendered == blockSize);
            checkNear(left[0], 0.25f);
            checkNear(right[blockSize - 1], -0.5f);
        }
    }

    HDMIRingStats stats;
    HDMIRingGetStats(ring, &stats);
    assert(stats.inputFrames == produced);
    assert(stats.renderedFrames + stats.silenceFrames == (uint64_t)blocks * blockSize);
    assert(stats.inputFrames > 40 * 65536);
    assert(stats.droppedFrames == 0);
    assert(stats.bufferedFrames > 500 && stats.bufferedFrames < 2500);
    printf("Capture clock %.0f Hz, output %.0f Hz: %u buffered frames after %u blocks\n",
           actualCaptureRate, outputRate, stats.bufferedFrames, blocks);
    HDMIRingDestroy(ring);
}

static void testStalledOutput(void) {
    enum { requestedFrames = 100000 };
    HDMIRing *ring = HDMIRingCreate(48000, 48000);
    assert(ring != NULL);
    float *samples = calloc(requestedFrames, sizeof(*samples));
    assert(samples != NULL);
    for (int frame = 0; frame < requestedFrames; ++frame) samples[frame] = 0.4f;
    uint32_t accepted = HDMIRingWriteInterleaved(ring, samples, requestedFrames, 1);
    assert(accepted < requestedFrames);
    assert(HDMIRingWriteInterleaved(ring, samples, blockSize, 1) == 0);

    float left[blockSize];
    assert(HDMIRingReadPlanar(ring, left, NULL, blockSize) == blockSize);
    checkNear(left[blockSize - 1], 0.4f);
    HDMIRingStats stats;
    HDMIRingGetStats(ring, &stats);
    assert(stats.droppedFrames > requestedFrames - accepted);
    assert(stats.bufferedFrames < 1500);
    assert(HDMIRingWriteInterleaved(ring, samples, blockSize, 1) == blockSize);
    free(samples);
    HDMIRingDestroy(ring);
}

static void checkAppMix(HDMIRing *ring, HDMIAppMixer *mixer,
                        float chromeGain, float musicGain, float masterGain) {
    float remainder[blockSize];
    float chrome[blockSize * 2];
    float musicLeft[blockSize];
    float musicRight[blockSize];
    float thirdApp[blockSize];
    for (int frame = 0; frame < blockSize; ++frame) {
        remainder[frame] = 0.05f;
        chrome[frame * 2] = 0.20f;
        chrome[frame * 2 + 1] = 0.10f;
        musicLeft[frame] = 0.30f;
        musicRight[frame] = -0.15f;
        thirdApp[frame] = 0.16f;
    }

    const HDMIRingMixerInput apps[] = {
        {chrome, chrome + 1, blockSize, 2},
        {musicLeft, musicRight, blockSize, 1},
        {thirdApp, NULL, blockSize, 1}
    };
    HDMIAppMixerSetGain(mixer, 0, chromeGain);
    HDMIAppMixerSetGain(mixer, 1, musicGain);
    HDMIRingSetGain(ring, masterGain);
    float left[blockSize];
    float right[blockSize];
    for (int block = 0; block < 16; ++block) {
        assert(HDMIRingWriteMix(ring, mixer, (HDMIRingMixerInput){remainder, NULL, blockSize, 1},
                               apps, 3) == blockSize);
        HDMIRingReadPlanar(ring, left, right, blockSize);
    }
    float expectedLeft = (0.05f + chromeGain * 0.20f + musicGain * 0.30f + 0.08f) * masterGain;
    float expectedRight = (0.05f + chromeGain * 0.10f - musicGain * 0.15f + 0.08f) * masterGain;
    for (int frame = 0; frame < blockSize; ++frame) {
        checkNear(left[frame], expectedLeft);
        checkNear(right[frame], expectedRight);
    }

    HDMIRingAppStats stats;
    checkNear(HDMIAppMixerGetRemainderPeak(mixer), 0.05f);
    HDMIAppMixerGetStats(mixer, 0, &stats);
    checkNear(stats.inputPeak, 0.20f);
    checkNear(stats.mixedPeak, 0.20f * chromeGain);
    HDMIAppMixerGetStats(mixer, 1, &stats);
    checkNear(stats.inputPeak, 0.30f);
    checkNear(stats.mixedPeak, 0.30f * musicGain);
    HDMIAppMixerGetStats(mixer, 2, &stats);
    checkNear(stats.inputPeak, 0.16f);
    checkNear(stats.mixedPeak, 0.08f);
}

static void testAppMixer(void) {
    HDMIRing *ring = HDMIRingCreate(48000, 48000);
    HDMIAppMixer *mixer = HDMIAppMixerCreate(48000, 3);
    assert(ring != NULL && mixer != NULL);
    HDMIAppMixerSetInitialGain(mixer, 2, 0.5f);
    checkAppMix(ring, mixer, 1, 1, 1);
    checkAppMix(ring, mixer, 0.25f, 1, 1);
    checkAppMix(ring, mixer, 0, 1, 1);
    checkAppMix(ring, mixer, 1, 0, 1);
    checkAppMix(ring, mixer, 1, 0.4f, 0.5f);
    checkAppMix(ring, mixer, 1, 0.4f, 0);
    HDMIAppMixerDestroy(mixer);

    // One tap can be inactive or return fewer frames than the other taps.
    // A new topology keeps the same output ring and starts with saved gains.
    mixer = HDMIAppMixerCreate(48000, 2);
    assert(mixer != NULL);
    HDMIAppMixerSetInitialGain(mixer, 0, 0);
    float chrome[blockSize] = {0.2f};
    const HDMIRingMixerInput apps[] = {{chrome, NULL, 1, 1}, {0}};
    const HDMIRingMixerInput silent = {NULL, NULL, blockSize, 1};
    assert(HDMIRingWriteMix(ring, mixer, silent, apps, 1) == 0);
    assert(HDMIRingWriteMix(ring, mixer, silent, apps, 2) == blockSize);
    HDMIRingAppStats stats;
    checkNear(HDMIAppMixerGetRemainderPeak(mixer), 0);
    HDMIAppMixerGetStats(mixer, 0, &stats);
    checkNear(stats.inputPeak, 0.2f);
    checkNear(stats.mixedPeak, 0);
    HDMIAppMixerGetStats(mixer, 1, &stats);
    checkNear(stats.inputPeak, 0);
    checkNear(stats.mixedPeak, 0);
    HDMIAppMixerDestroy(mixer);
    HDMIRingDestroy(ring);
}

int main(void) {
    assert(HDMIRingCreate(0, 48000) == NULL);
    assert(HDMIRingCreate(44100, NAN) == NULL);
    testGainAndUnderrun();
    testClockDrift(48024);
    testClockDrift(47976);
    testStalledOutput();
    testAppMixer();
    puts("HDMI audio buffer tests passed.");
    return 0;
}

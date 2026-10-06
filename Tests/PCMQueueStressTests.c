#include "../SuperNotch/PCMQueue.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>

static SNPCMQueue *queue;
static _Atomic bool finished;

static void *produce(void *unused) {
    (void)unused;
    float samples[64];
    AudioBufferList input = { .mNumberBuffers = 1,
        .mBuffers = {{ .mNumberChannels = 1, .mDataByteSize = sizeof(samples), .mData = samples }} };
    for (unsigned i = 1; i <= 100000; i++) {
        for (unsigned j = 0; j < 64; j++) samples[j] = (float)i;
        SNPCMQueuePush(queue, &input);
        if (i % 32 == 0) sched_yield();
    }
    atomic_store_explicit(&finished, true, memory_order_release);
    return NULL;
}

int main(void) {
    queue = SNPCMQueueCreate(1, 1, sizeof(float), 64);
    assert(queue);
    atomic_init(&finished, false);
    pthread_t producer;
    assert(pthread_create(&producer, NULL, produce, NULL) == 0);
    float samples[64], previous = 0;
    unsigned chunks = 0;
    while (!atomic_load_explicit(&finished, memory_order_acquire) || SNPCMQueueHasData(queue)) {
        AudioBufferList output = { .mNumberBuffers = 1,
            .mBuffers = {{ .mNumberChannels = 1, .mDataByteSize = sizeof(samples), .mData = samples }} };
        uint32_t frames = 0;
        if (!SNPCMQueueRead(queue, &output, 64, &frames)) { sched_yield(); continue; }
        assert(frames == 64 && samples[0] > previous);
        for (unsigned j = 0; j < frames; j++) assert(samples[j] == samples[0]);
        previous = samples[0];
        chunks++;
    }
    assert(pthread_join(producer, NULL) == 0);
    assert(chunks > 0 && !SNPCMQueueTakeFault(queue));
    SNPCMQueueDestroy(queue);
    puts("PASS: concurrent producer/consumer never expose reused or partially copied PCM");
    return 0;
}

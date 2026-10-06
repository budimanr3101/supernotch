#include "PCMQueue.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define SLOT_COUNT 32u
struct SNPCMQueue {
    _Atomic uint32_t writeIndex, readIndex, drops;
    _Atomic bool fault;
    uint32_t buffers, channels, bytesPerFrame, maxFrames;
    uint32_t frames[SLOT_COUNT];
    unsigned char *storage;
};

SNPCMQueue *SNPCMQueueCreate(uint32_t buffers, uint32_t channels,
                            uint32_t bytesPerFrame, uint32_t maxFrames) {
    if (!buffers || buffers > 2 || !channels || channels > 2 ||
        !bytesPerFrame || bytesPerFrame > 16 || !maxFrames || maxFrames > 65536)
        return NULL;
    SNPCMQueue *q = calloc(1, sizeof(*q));
    if (!q) return NULL;
    atomic_init(&q->writeIndex, 0); atomic_init(&q->readIndex, 0);
    atomic_init(&q->drops, 0); atomic_init(&q->fault, false);
    // Never fall back to a hidden mutex in the HAL callback.
    if (!atomic_is_lock_free(&q->writeIndex) || !atomic_is_lock_free(&q->readIndex) ||
        !atomic_is_lock_free(&q->drops) || !atomic_is_lock_free(&q->fault)) {
        free(q); return NULL;
    }
    q->buffers = buffers; q->channels = channels;
    q->bytesPerFrame = bytesPerFrame; q->maxFrames = maxFrames;
    q->storage = calloc(SLOT_COUNT * buffers, (size_t)bytesPerFrame * maxFrames);
    if (!q->storage) { free(q); return NULL; }
    return q;
}

void SNPCMQueueDestroy(SNPCMQueue *q) {
    if (q) { free(q->storage); free(q); }
}

void SNPCMQueuePush(SNPCMQueue *q, const AudioBufferList *input) {
    if (!q || !input) return;
    if (!input->mNumberBuffers) return; // No data in this HAL cycle.
    if (input->mNumberBuffers != q->buffers) {
        atomic_store_explicit(&q->fault, true, memory_order_relaxed); return;
    }
    uint32_t bytes = input->mBuffers[0].mDataByteSize;
    if (!bytes) return;
    if (bytes % q->bytesPerFrame || bytes / q->bytesPerFrame > q->maxFrames) {
        atomic_store_explicit(&q->fault, true, memory_order_relaxed); return;
    }
    for (uint32_t b = 0; b < q->buffers; b++) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        if (buffer->mNumberChannels != q->channels || buffer->mDataByteSize != bytes) {
            atomic_store_explicit(&q->fault, true, memory_order_relaxed); return;
        }
        if (!buffer->mData) return; // Disabled input stream.
    }
    uint32_t write = atomic_load_explicit(&q->writeIndex, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&q->readIndex, memory_order_acquire);
    if (write - read >= SLOT_COUNT) {
        atomic_fetch_add_explicit(&q->drops, 1, memory_order_relaxed); return;
    }
    uint32_t slot = write % SLOT_COUNT;
    size_t stride = (size_t)q->maxFrames * q->bytesPerFrame;
    for (uint32_t b = 0; b < q->buffers; b++)
        memcpy(q->storage + (slot * q->buffers + b) * stride, input->mBuffers[b].mData, bytes);
    q->frames[slot] = bytes / q->bytesPerFrame;
    atomic_store_explicit(&q->writeIndex, write + 1, memory_order_release);
}

bool SNPCMQueueHasData(SNPCMQueue *q) {
    return q && atomic_load_explicit(&q->readIndex, memory_order_relaxed) !=
                atomic_load_explicit(&q->writeIndex, memory_order_acquire);
}

bool SNPCMQueueRead(SNPCMQueue *q, AudioBufferList *output,
                    uint32_t capacity, uint32_t *frames) {
    if (!q || !output || !frames) return false;
    uint32_t read = atomic_load_explicit(&q->readIndex, memory_order_relaxed);
    if (read == atomic_load_explicit(&q->writeIndex, memory_order_acquire)) return false;
    uint32_t slot = read % SLOT_COUNT, count = q->frames[slot];
    uint32_t bytes = count * q->bytesPerFrame;
    if (output->mNumberBuffers != q->buffers || capacity < count) return false;
    for (uint32_t b = 0; b < q->buffers; b++)
        if (!output->mBuffers[b].mData || output->mBuffers[b].mDataByteSize < bytes) return false;
    size_t stride = (size_t)q->maxFrames * q->bytesPerFrame;
    for (uint32_t b = 0; b < q->buffers; b++) {
        memcpy(output->mBuffers[b].mData, q->storage + (slot * q->buffers + b) * stride, bytes);
        output->mBuffers[b].mDataByteSize = bytes;
    }
    *frames = count;
    atomic_store_explicit(&q->readIndex, read + 1, memory_order_release);
    return true;
}
bool SNPCMQueueTakeFault(SNPCMQueue *q) {
    return q && atomic_exchange_explicit(&q->fault, false, memory_order_relaxed);
}
uint32_t SNPCMQueueTakeDrops(SNPCMQueue *q) {
    return q ? atomic_exchange_explicit(&q->drops, 0, memory_order_relaxed) : 0;
}

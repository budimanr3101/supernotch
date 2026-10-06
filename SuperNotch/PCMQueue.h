#ifndef SUPERNOTCH_PCM_QUEUE_H
#define SUPERNOTCH_PCM_QUEUE_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

// One HAL producer and one worker consumer. The queue owns all copied PCM.
// Destroy only AFTER stopping and destroying the IOProc.
typedef struct SNPCMQueue SNPCMQueue;
SNPCMQueue *SNPCMQueueCreate(uint32_t buffers, uint32_t channelsPerBuffer,
                            uint32_t bytesPerFrame, uint32_t maxFrames);
void SNPCMQueueDestroy(SNPCMQueue *queue);
void SNPCMQueuePush(SNPCMQueue *queue, const AudioBufferList *input);
bool SNPCMQueueHasData(SNPCMQueue *queue);
bool SNPCMQueueRead(SNPCMQueue *queue, AudioBufferList *output,
                    uint32_t capacityFrames, uint32_t *frames);
bool SNPCMQueueTakeFault(SNPCMQueue *queue);
uint32_t SNPCMQueueTakeDrops(SNPCMQueue *queue);
#endif

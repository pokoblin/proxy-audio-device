#ifndef __AudioRingBuffer_h__
#define __AudioRingBuffer_h__

#include <CoreServices/CoreServices.h>
#include <atomic>

// Single-producer / single-consumer ring buffer used to cache a couple of
// seconds of captured input and serve it back to the output IOProc (which
// runs on a real-time audio thread). The three frame cursors below are
// read from one thread while being updated by another, so they are atomic;
// Store() publishes new data with release ordering and Fetch() reads with
// acquire ordering.
class AudioRingBuffer {
  public:
    AudioRingBuffer(UInt32 bytesPerFrame, UInt32 capacityFrames);
    ~AudioRingBuffer();

    void Allocate(UInt32 bytesPerFrame, UInt32 capacityFrames);
    void Clear();
    bool Store(const Byte *data, UInt32 nFrames, SInt64 frameNumber);
    bool Fetch(Byte *data, UInt32 nFrames, SInt64 frameNumber);

    // Thread-safe snapshot helpers for readers (audio IOProc). Pair with
    // Store()'s release writes.
    SInt64 StartFrame() const { return mStartFrame.load(std::memory_order_acquire); }
    SInt64 EndFrame() const { return mEndFrame.load(std::memory_order_acquire); }

    UInt32 mBytesPerFrame;
    UInt32 mCapacityFrames;
    UInt32 mCapacityBytes;
    Byte *mBuffer;
    std::atomic<UInt32> mStartOffset;
    std::atomic<SInt64> mStartFrame;
    std::atomic<SInt64> mEndFrame;
};

#endif // __AudioRingBuffer_h__

#include "AudioRingBuffer.h"

// Ring buffer layout:
//   - Writer (capture side) calls Store(); it is the *only* mutator of the
//     three cursors (mStartFrame, mEndFrame, mStartOffset).
//   - Reader (audio IOProc) calls Fetch() and also reads the cursors via
//     EndFrame()/StartFrame() to detect overruns.
// With a single writer and a single reader, atomic cursors with
// release/acquire ordering are sufficient: the memcpy of new audio data is
// published to the reader by the release-store to mEndFrame.

AudioRingBuffer::AudioRingBuffer(UInt32 bytesPerFrame, UInt32 capacityFrames)
    : mBytesPerFrame(0), mCapacityFrames(0), mCapacityBytes(0), mBuffer(NULL),
      mStartOffset(0), mStartFrame(0), mEndFrame(0) {
    Allocate(bytesPerFrame, capacityFrames);
}

AudioRingBuffer::~AudioRingBuffer() {
    if (mBuffer)
        free(mBuffer);
}

void AudioRingBuffer::Allocate(UInt32 bytesPerFrame, UInt32 capacityFrames) {
    if (mBuffer)
        free(mBuffer);

    mBytesPerFrame = bytesPerFrame;
    mCapacityFrames = capacityFrames;
    mCapacityBytes = bytesPerFrame * capacityFrames;
    mBuffer = (Byte *)malloc(mCapacityBytes);
    Clear();
}

void AudioRingBuffer::Clear() {
    if (mBuffer)
        memset(mBuffer, 0, mCapacityBytes);
    mStartOffset.store(0, std::memory_order_relaxed);
    mStartFrame.store(0, std::memory_order_relaxed);
    mEndFrame.store(0, std::memory_order_release);
}

static inline UInt32 FrameOffsetFor(SInt64 frameNumber, UInt32 startOffset, SInt64 startFrame,
                                    UInt32 bytesPerFrame, UInt32 capacityBytes) {
    return (startOffset + UInt32(frameNumber - startFrame) * bytesPerFrame) % capacityBytes;
}

bool AudioRingBuffer::Store(const Byte *data, UInt32 nFrames, SInt64 startFrame) {
    if (nFrames > mCapacityFrames)
        return false;

    // The writer is the only thread mutating state, so self-reads are
    // relaxed — we only need release semantics when publishing updates to
    // the reader.
    SInt64 curStart = mStartFrame.load(std::memory_order_relaxed);
    SInt64 curEnd = mEndFrame.load(std::memory_order_relaxed);
    UInt32 curStartOffset = mStartOffset.load(std::memory_order_relaxed);

    SInt64 endFrame = startFrame + nFrames;
    if (startFrame >= curEnd + mCapacityFrames) {
        // writing more than one buffer ahead -- fine but that means that everything we have is now too far in the past
        Clear();
        curStart = 0;
        curEnd = 0;
        curStartOffset = 0;
    }

    if (curStart == 0) {
        // empty buffer: copy the data first, then publish the new cursors
        // so the reader only sees them once the data is valid.
        memcpy(mBuffer, data, nFrames * mBytesPerFrame);
        mStartOffset.store(0, std::memory_order_relaxed);
        mStartFrame.store(startFrame, std::memory_order_relaxed);
        mEndFrame.store(endFrame, std::memory_order_release);
    } else {
        UInt32 offset0, offset1, nBytes;
        if (endFrame > curEnd) {
            // advancing (as will be usual with sequential stores)

            if (startFrame > curEnd) {
                // we are skipping some samples, so zero the range we are skipping
                offset0 = FrameOffsetFor(curEnd, curStartOffset, curStart, mBytesPerFrame, mCapacityBytes);
                offset1 = FrameOffsetFor(startFrame, curStartOffset, curStart, mBytesPerFrame, mCapacityBytes);
                if (offset0 < offset1)
                    memset(mBuffer + offset0, 0, offset1 - offset0);
                else {
                    nBytes = mCapacityBytes - offset0;
                    memset(mBuffer + offset0, 0, nBytes);
                    memset(mBuffer, 0, offset1);
                }
            }

            // except for the case of not having wrapped yet, we will normally
            // have to advance the start. Advance it *before* the memcpy so a
            // concurrent reader cannot be reading a region we're about to
            // overwrite.
            SInt64 newStart = endFrame - mCapacityFrames;
            if (newStart > curStart) {
                UInt32 newStartOffset =
                    (UInt32)(curStartOffset + ((UInt64)newStart - curStart) * mBytesPerFrame) % mCapacityBytes;
                mStartOffset.store(newStartOffset, std::memory_order_relaxed);
                mStartFrame.store(newStart, std::memory_order_release);
                curStart = newStart;
                curStartOffset = newStartOffset;
            }
            curEnd = endFrame;
        }

        // now everything is lined up and we can just write the new data
        offset0 = FrameOffsetFor(startFrame, curStartOffset, curStart, mBytesPerFrame, mCapacityBytes);
        offset1 = FrameOffsetFor(endFrame, curStartOffset, curStart, mBytesPerFrame, mCapacityBytes);
        if (offset0 < offset1)
            memcpy(mBuffer + offset0, data, offset1 - offset0);
        else {
            nBytes = mCapacityBytes - offset0;
            memcpy(mBuffer + offset0, data, nBytes);
            memcpy(mBuffer, data + nBytes, offset1);
        }

        // Publish the new end-frame only after the data memcpy completes,
        // so the reader never observes an end-frame advance without the
        // corresponding samples being in memory.
        mEndFrame.store(curEnd, std::memory_order_release);
    }

    return true;
}

bool AudioRingBuffer::Fetch(Byte *data, UInt32 nFrames, SInt64 startFrame) {
    SInt64 endFrame = startFrame + nFrames;

    // Acquire pairs with Store()'s release on mEndFrame/mStartFrame so any
    // memcpy the writer did before publishing is visible here.
    SInt64 curEnd = mEndFrame.load(std::memory_order_acquire);
    SInt64 curStart = mStartFrame.load(std::memory_order_acquire);
    UInt32 curStartOffset = mStartOffset.load(std::memory_order_relaxed);

    if (endFrame < curStart || startFrame >= curEnd) {
        memset(data, 0, mBytesPerFrame * nFrames);
        return true;
    }

    bool bufferOverrun = false;

    if (startFrame < curStart) {
        UInt64 bytes = (curStart - startFrame) * mBytesPerFrame;
        memset(data, 0, bytes);
        startFrame = curStart;
        data += bytes;
        bufferOverrun = true;
    }

    if (endFrame > curEnd) {
        UInt64 bytes = (endFrame - curEnd) * mBytesPerFrame;
        UInt64 offset = (curEnd - startFrame) * mBytesPerFrame;
        memset(data + offset, 0, bytes);
        endFrame = curEnd;
        bufferOverrun = true;
    }

    if (startFrame == endFrame) {
        return true;
    }

    UInt32 offset0 = FrameOffsetFor(startFrame, curStartOffset, curStart, mBytesPerFrame, mCapacityBytes);
    UInt32 offset1 = FrameOffsetFor(endFrame, curStartOffset, curStart, mBytesPerFrame, mCapacityBytes);

    if (offset0 < offset1)
        memcpy(data, mBuffer + offset0, offset1 - offset0);
    else {
        UInt32 nBytes = mCapacityBytes - offset0;
        memcpy(data, mBuffer + offset0, nBytes);
        memcpy(data + nBytes, mBuffer, offset1);
    }

    return bufferOverrun;
}

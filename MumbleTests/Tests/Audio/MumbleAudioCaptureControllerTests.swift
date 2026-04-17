import Foundation
import Testing
@testable import Mumble

struct MumbleAudioCaptureControllerTests {
    @Test
    func transmitAccumulatorSplitsSamplesIntoPacketSizedFrames() {
        var accumulator = MumbleTransmitPCMAccumulator()
        let inputSamples = (0..<1_000).map(Float.init)

        let frames = accumulator.append(samples: inputSamples)

        #expect(frames.count == 1)
        #expect(frames.first?.count == MumbleTransmitPCMAccumulator.packetFrameSize)
        #expect(frames.first?.first == 0)
        #expect(frames.first?.last == 959)
        #expect(accumulator.pendingSamples.count == 40)
    }

    @Test
    func transmitAccumulatorPadsFinalFrameOnStop() {
        var accumulator = MumbleTransmitPCMAccumulator()
        _ = accumulator.append(samples: [0.25, 0.5, 0.75])

        let finalFrame = accumulator.finishFrame()

        #expect(finalFrame.count == MumbleTransmitPCMAccumulator.packetFrameSize)
        #expect(Array(finalFrame.prefix(3)) == [0.25, 0.5, 0.75])
        #expect(finalFrame.dropFirst(3).allSatisfy { $0 == 0 })
        #expect(accumulator.pendingSamples.isEmpty)
    }

    @Test
    func frameSequencerAdvancesInTenMillisecondSteps() {
        var sequencer = MumbleTransmitFrameSequencer()

        let firstFrameNumber = sequencer.reserveFrameNumber(forPCMFrameCount: 960)
        let secondFrameNumber = sequencer.reserveFrameNumber(forPCMFrameCount: 960)

        #expect(firstFrameNumber == 0)
        #expect(secondFrameNumber == 2)
        #expect(sequencer.nextFrameNumber == 4)
    }
}

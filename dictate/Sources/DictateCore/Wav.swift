import Foundation

public enum Wav {
    public static func pcm16Mono(samples: [Int16], sampleRate: Int = 16000) -> Data {
        var data = Data()
        let dataBytes = samples.count * 2
        let chunkSize = 36 + dataBytes
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        data.append(uint32(UInt32(chunkSize)))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt 
        data.append(uint32(16))
        data.append(uint16(1)) // PCM
        data.append(uint16(1)) // mono
        data.append(uint32(UInt32(sampleRate)))
        data.append(uint32(UInt32(sampleRate * 2)))
        data.append(uint16(2))
        data.append(uint16(16))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        data.append(uint32(UInt32(dataBytes)))
        for sample in samples {
            data.append(uint16(UInt16(bitPattern: sample)))
        }
        return data
    }

    private static func uint16(_ value: UInt16) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: 2)
    }

    private static func uint32(_ value: UInt32) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: 4)
    }
}

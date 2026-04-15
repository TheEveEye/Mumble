import Foundation
import CommonCrypto

struct MumbleCryptState: Sendable {
    static let aesBlockSize = 16
    static let aesKeySize = 16

    private var rawKey = [UInt8](repeating: 0, count: aesKeySize)
    private var encryptIV = [UInt8](repeating: 0, count: aesBlockSize)
    private var decryptIV = [UInt8](repeating: 0, count: aesBlockSize)
    private var decryptHistory = [UInt8](repeating: 0, count: 0x100)

    private(set) var goodPackets = 0
    private(set) var latePackets = 0
    private(set) var lostPackets = 0

    var isValid: Bool {
        !rawKey.allSatisfy { $0 == 0 }
    }

    mutating func setKey(key: Data, clientNonce: Data, serverNonce: Data) -> Bool {
        guard
            key.count == Self.aesKeySize,
            clientNonce.count == Self.aesBlockSize,
            serverNonce.count == Self.aesBlockSize
        else {
            return false
        }

        rawKey = Array(key)
        encryptIV = Array(clientNonce)
        decryptIV = Array(serverNonce)
        decryptHistory = [UInt8](repeating: 0, count: 0x100)
        goodPackets = 0
        latePackets = 0
        lostPackets = 0
        return true
    }

    mutating func setDecryptIV(_ nonce: Data) -> Bool {
        guard nonce.count == Self.aesBlockSize else {
            return false
        }

        decryptIV = Array(nonce)
        return true
    }

    func currentEncryptIV() -> Data {
        Data(encryptIV)
    }

    mutating func encrypt(_ plaintext: Data) -> Data? {
        guard isValid else {
            return nil
        }

        for index in 0..<Self.aesBlockSize {
            encryptIV[index] &+= 1
            if encryptIV[index] != 0 {
                break
            }
        }

        guard let encrypted = ocbEncrypt(plaintext, nonce: encryptIV) else {
            return nil
        }

        var packet = Data()
        packet.append(encryptIV[0])
        packet.append(encrypted.tag.prefix(3))
        packet.append(encrypted.ciphertext)
        return packet
    }

    mutating func decrypt(_ packet: Data) -> Data? {
        guard isValid, packet.count >= 4 else {
            return nil
        }

        let ivByte = packet[packet.startIndex]
        let ciphertext = packet.dropFirst(4)

        let savedIV = decryptIV
        var workingIV = decryptIV
        var restore = false
        var late = 0
        var lost = 0

        if UInt8(truncatingIfNeeded: decryptIV[0] &+ 1) == ivByte {
            if ivByte > decryptIV[0] {
                workingIV[0] = ivByte
            } else if ivByte < decryptIV[0] {
                workingIV[0] = ivByte
                for index in 1..<Self.aesBlockSize {
                    workingIV[index] &+= 1
                    if workingIV[index] != 0 {
                        break
                    }
                }
            } else {
                return nil
            }
        } else {
            var diff = Int(ivByte) - Int(decryptIV[0])
            if diff > 128 {
                diff -= 256
            } else if diff < -128 {
                diff += 256
            }

            if ivByte < decryptIV[0] && diff > -30 && diff < 0 {
                late = 1
                lost = -1
                workingIV[0] = ivByte
                restore = true
            } else if ivByte > decryptIV[0] && diff > -30 && diff < 0 {
                late = 1
                lost = -1
                workingIV[0] = ivByte
                for index in 1..<Self.aesBlockSize {
                    workingIV[index] &-= 1
                    if workingIV[index] != 0xFF {
                        break
                    }
                }
                restore = true
            } else if ivByte > decryptIV[0] && diff > 0 {
                lost = Int(ivByte) - Int(decryptIV[0]) - 1
                workingIV[0] = ivByte
            } else if ivByte < decryptIV[0] && diff > 0 {
                lost = 256 - Int(decryptIV[0]) + Int(ivByte) - 1
                workingIV[0] = ivByte
                for index in 1..<Self.aesBlockSize {
                    workingIV[index] &+= 1
                    if workingIV[index] != 0 {
                        break
                    }
                }
            } else {
                return nil
            }

            if decryptHistory[Int(workingIV[0])] == workingIV[1] {
                return nil
            }
        }

        guard let decrypted = ocbDecrypt(ciphertext, nonce: workingIV) else {
            return nil
        }

        let transmittedTag = Array(packet.dropFirst().prefix(3))
        guard Array(decrypted.tag.prefix(3)) == transmittedTag else {
            return nil
        }

        decryptHistory[Int(workingIV[0])] = workingIV[1]

        if !restore {
            decryptIV = workingIV
        } else {
            decryptIV = savedIV
        }

        goodPackets += 1
        latePackets = max(0, latePackets + late)
        lostPackets = max(0, lostPackets + lost)
        return decrypted.plaintext
    }

    private func ocbEncrypt(_ plaintext: Data, nonce: [UInt8]) -> (ciphertext: Data, tag: Data)? {
        var checksum = [UInt8](repeating: 0, count: Self.aesBlockSize)
        guard var delta = aesECBEncrypt(block: nonce) else {
            return nil
        }

        var encrypted = Data(count: plaintext.count)
        plaintext.withUnsafeBytes { plainBytes in
            encrypted.withUnsafeMutableBytes { encryptedBytes in
                guard
                    let plainBase = plainBytes.bindMemory(to: UInt8.self).baseAddress,
                    let encryptedBase = encryptedBytes.bindMemory(to: UInt8.self).baseAddress
                else {
                    return
                }

                let fullBlockCount = plaintext.count / Self.aesBlockSize
                let trailingCount = plaintext.count % Self.aesBlockSize
                var fullBlocksToProcess = fullBlockCount
                if trailingCount == 0, fullBlockCount > 0 {
                    fullBlocksToProcess -= 1
                }

                for blockIndex in 0..<fullBlocksToProcess {
                    s2(&delta)

                    let blockStart = blockIndex * Self.aesBlockSize
                    let plainBlock = Array(UnsafeBufferPointer(
                        start: plainBase.advanced(by: blockStart),
                        count: Self.aesBlockSize
                    ))
                    var tmp = xor(delta, plainBlock)

                    if blockIndex == fullBlocksToProcess - 1, trailingCount == 0, isXEXStarAttackCandidate(plainBlock) {
                        tmp[0] ^= 1
                    }

                    guard let encryptedBlock = aesECBEncrypt(block: tmp) else {
                        return
                    }

                    let cipherBlock = xor(delta, encryptedBlock)
                    for byteIndex in 0..<Self.aesBlockSize {
                        encryptedBase[blockStart + byteIndex] = cipherBlock[byteIndex]
                    }

                    let checksumInput: [UInt8]
                    if blockIndex == fullBlocksToProcess - 1, trailingCount == 0, isXEXStarAttackCandidate(plainBlock) {
                        var adjusted = plainBlock
                        adjusted[0] ^= 1
                        checksumInput = adjusted
                    } else {
                        checksumInput = plainBlock
                    }

                    checksum = xor(checksum, checksumInput)
                }

                let lastBlockOffset = fullBlocksToProcess * Self.aesBlockSize
                let remainingCount = plaintext.count - lastBlockOffset

                s2(&delta)
                var tmp = [UInt8](repeating: 0, count: Self.aesBlockSize)
                tmp[Self.aesBlockSize - 1] = UInt8(truncatingIfNeeded: remainingCount * 8)
                tmp = xor(tmp, delta)

                guard let pad = aesECBEncrypt(block: tmp) else {
                    return
                }

                var lastPlainBlock = [UInt8](repeating: 0, count: Self.aesBlockSize)
                if remainingCount > 0 {
                    for byteIndex in 0..<remainingCount {
                        lastPlainBlock[byteIndex] = plainBase[lastBlockOffset + byteIndex]
                    }
                }
                if remainingCount < Self.aesBlockSize {
                    for byteIndex in remainingCount..<Self.aesBlockSize {
                        lastPlainBlock[byteIndex] = pad[byteIndex]
                    }
                }

                checksum = xor(checksum, lastPlainBlock)
                let encryptedTail = xor(pad, lastPlainBlock)
                if remainingCount > 0 {
                    for byteIndex in 0..<remainingCount {
                        encryptedBase[lastBlockOffset + byteIndex] = encryptedTail[byteIndex]
                    }
                }
            }
        }

        s3(&delta)
        guard let tag = aesECBEncrypt(block: xor(delta, checksum)) else {
            return nil
        }

        return (encrypted, Data(tag))
    }

    private func ocbDecrypt(_ ciphertext: Data.SubSequence, nonce: [UInt8]) -> (plaintext: Data, tag: Data)? {
        var checksum = [UInt8](repeating: 0, count: Self.aesBlockSize)
        guard var delta = aesECBEncrypt(block: nonce) else {
            return nil
        }

        let ciphertextData = Data(ciphertext)
        var plaintext = Data(count: ciphertextData.count)

        ciphertextData.withUnsafeBytes { encryptedBytes in
            plaintext.withUnsafeMutableBytes { plainBytes in
                guard
                    let encryptedBase = encryptedBytes.bindMemory(to: UInt8.self).baseAddress,
                    let plainBase = plainBytes.bindMemory(to: UInt8.self).baseAddress
                else {
                    return
                }

                let fullBlockCount = ciphertextData.count / Self.aesBlockSize
                let trailingCount = ciphertextData.count % Self.aesBlockSize
                var fullBlocksToProcess = fullBlockCount
                if trailingCount == 0, fullBlockCount > 0 {
                    fullBlocksToProcess -= 1
                }

                for blockIndex in 0..<fullBlocksToProcess {
                    s2(&delta)

                    let blockStart = blockIndex * Self.aesBlockSize
                    let cipherBlock = Array(UnsafeBufferPointer(
                        start: encryptedBase.advanced(by: blockStart),
                        count: Self.aesBlockSize
                    ))
                    let tmp = xor(delta, cipherBlock)
                    guard let decryptedBlock = aesECBDecrypt(block: tmp) else {
                        return
                    }

                    let plainBlock = xor(delta, decryptedBlock)
                    checksum = xor(checksum, plainBlock)

                    for byteIndex in 0..<Self.aesBlockSize {
                        plainBase[blockStart + byteIndex] = plainBlock[byteIndex]
                    }
                }

                let lastBlockOffset = fullBlocksToProcess * Self.aesBlockSize
                let remainingCount = ciphertextData.count - lastBlockOffset

                s2(&delta)
                var tmp = [UInt8](repeating: 0, count: Self.aesBlockSize)
                tmp[Self.aesBlockSize - 1] = UInt8(truncatingIfNeeded: remainingCount * 8)
                tmp = xor(tmp, delta)

                guard let pad = aesECBEncrypt(block: tmp) else {
                    return
                }

                var lastCipherBlock = [UInt8](repeating: 0, count: Self.aesBlockSize)
                if remainingCount > 0 {
                    for byteIndex in 0..<remainingCount {
                        lastCipherBlock[byteIndex] = encryptedBase[lastBlockOffset + byteIndex]
                    }
                }

                let lastPlainBlock = xor(lastCipherBlock, pad)
                checksum = xor(checksum, lastPlainBlock)
                if remainingCount > 0 {
                    for byteIndex in 0..<remainingCount {
                        plainBase[lastBlockOffset + byteIndex] = lastPlainBlock[byteIndex]
                    }
                }
            }
        }

        s3(&delta)
        guard let tag = aesECBEncrypt(block: xor(delta, checksum)) else {
            return nil
        }

        return (plaintext, Data(tag))
    }

    private func isXEXStarAttackCandidate(_ block: [UInt8]) -> Bool {
        guard block.count == Self.aesBlockSize else {
            return false
        }

        return block.dropLast().allSatisfy { $0 == 0 }
    }

    private func aesECBEncrypt(block: [UInt8]) -> [UInt8]? {
        crypt(block: block, operation: CCOperation(kCCEncrypt))
    }

    private func aesECBDecrypt(block: [UInt8]) -> [UInt8]? {
        crypt(block: block, operation: CCOperation(kCCDecrypt))
    }

    private func crypt(block: [UInt8], operation: CCOperation) -> [UInt8]? {
        guard block.count == Self.aesBlockSize else {
            return nil
        }

        var output = [UInt8](repeating: 0, count: Self.aesBlockSize)
        var outputLength = 0

        let status = rawKey.withUnsafeBytes { keyBytes in
            block.withUnsafeBytes { blockBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        Self.aesKeySize,
                        nil,
                        blockBytes.baseAddress,
                        Self.aesBlockSize,
                        outputBytes.baseAddress,
                        Self.aesBlockSize,
                        &outputLength
                    )
                }
            }
        }

        guard status == kCCSuccess, outputLength == Self.aesBlockSize else {
            return nil
        }

        return output
    }

    private func xor(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        zip(lhs, rhs).map { $0 ^ $1 }
    }

    private func s2(_ block: inout [UInt8]) {
        let carry: UInt8 = (block[0] & 0x80) != 0 ? 1 : 0
        for index in 0..<(Self.aesBlockSize - 1) {
            let nextCarry: UInt8 = (block[index + 1] & 0x80) != 0 ? 1 : 0
            block[index] = UInt8(truncatingIfNeeded: (block[index] << 1) | nextCarry)
        }
        block[Self.aesBlockSize - 1] = UInt8(truncatingIfNeeded: (block[Self.aesBlockSize - 1] << 1) ^ (carry * 0x87))
    }

    private func s3(_ block: inout [UInt8]) {
        let original = block
        var doubled = original
        s2(&doubled)
        block = xor(original, doubled)
    }
}

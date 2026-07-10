import Foundation
import CoreMedia

/// Minimal MPEG-TS muxer for a single H.264 video elementary stream, enough for
/// VLC / QuickTime / ffmpeg to play a live stream. Emits 188-byte TS packets:
/// a PAT + PMT before each keyframe (so a late joiner can start), then the frame
/// as one PES split across TS packets. H.264 NAL units are given in Annex-B form
/// (no start codes); this class adds start codes + an AUD and builds the PES.
final class TSMuxer {
    private let pmtPID: UInt16 = 0x1000
    private let videoPID: UInt16 = 0x0100
    private let pcrPID: UInt16 = 0x0100
    private let streamType: UInt8 = 0x1B   // H.264

    private var patCC: UInt8 = 0
    private var pmtCC: UInt8 = 0
    private var videoCC: UInt8 = 0

    /// Package a coded frame (its NAL units) into TS packets. On a keyframe we
    /// prepend PAT+PMT. `pts` drives the PTS/PCR (90 kHz).
    func package(nalus: [Data], pts: CMTime, keyframe: Bool) -> Data {
        var out = Data()
        let pts90k = UInt64(max(0, CMTimeGetSeconds(pts)) * 90_000)

        if keyframe {
            out.append(packet(pid: 0x0000, payload: patPayload(), cc: &patCC, pusi: true, pcr: nil))
            out.append(packet(pid: pmtPID, payload: pmtPayload(), cc: &pmtCC, pusi: true, pcr: nil))
        }

        // Elementary stream: AUD + start-code-prefixed NALs.
        var es = Data([0x00, 0x00, 0x00, 0x01, 0x09, 0xF0])  // access unit delimiter
        for nalu in nalus {
            es.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            es.append(nalu)
        }
        let pes = pesPacket(payload: es, pts90k: pts90k)

        // Split PES across TS packets; first carries PUSI + PCR.
        var offset = 0
        var first = true
        while offset < pes.count {
            let remaining = pes.count - offset
            var payload = Data()
            var adaptation = Data()

            if first {
                adaptation = adaptationField(pcr90k: pts90k, wantRandomAccess: keyframe)
            }
            // TS payload budget = 184 minus adaptation field bytes (if any).
            let header4 = 4
            let adLen = adaptation.count
            var budget = 188 - header4 - adLen
            // If this is the LAST chunk and it doesn't fill the packet, stuff the
            // adaptation field so the packet stays exactly 188 bytes.
            if remaining < budget && !first {
                let stuffing = budget - remaining
                adaptation = stuffingAdaptation(bytes: stuffing)
                budget = 188 - header4 - adaptation.count
            } else if remaining < budget && first {
                let stuffing = budget - remaining
                adaptation.append(contentsOf: [UInt8](repeating: 0xFF, count: stuffing))
                adaptation[0] = UInt8(adaptation.count - 1)   // fix adaptation length
                budget = 188 - header4 - adaptation.count
            }
            let take = min(budget, remaining)
            payload = pes.subdata(in: (pes.startIndex + offset)..<(pes.startIndex + offset + take))
            offset += take

            out.append(tsPacket(pid: videoPID, payload: payload, adaptation: adaptation,
                                cc: &videoCC, pusi: first))
            first = false
        }
        return out
    }

    // MARK: - TS packet assembly

    /// Build a 188-byte TS packet with an explicit adaptation field + payload.
    private func tsPacket(pid: UInt16, payload: Data, adaptation: Data, cc: inout UInt8, pusi: Bool) -> Data {
        var p = Data(capacity: 188)
        p.append(0x47)
        let b1 = UInt8((pusi ? 0x40 : 0x00) | (UInt16(pid) >> 8) & 0x1F)
        p.append(b1)
        p.append(UInt8(pid & 0xFF))
        let hasAdaptation = !adaptation.isEmpty
        let afc: UInt8 = hasAdaptation ? (payload.isEmpty ? 0x20 : 0x30) : 0x10
        p.append(afc | (cc & 0x0F))
        cc = (cc &+ 1) & 0x0F
        if hasAdaptation { p.append(adaptation) }
        p.append(payload)
        if p.count < 188 { p.append(contentsOf: [UInt8](repeating: 0xFF, count: 188 - p.count)) }
        return p
    }

    /// Simple packet for PSI (PAT/PMT): pointer_field + section, padded to 188.
    private func packet(pid: UInt16, payload: Data, cc: inout UInt8, pusi: Bool, pcr: UInt64?) -> Data {
        var body = Data([0x00])   // pointer_field
        body.append(payload)
        return tsPacket(pid: pid, payload: body, adaptation: Data(), cc: &cc, pusi: pusi)
    }

    // MARK: - Adaptation field (with PCR)

    private func adaptationField(pcr90k: UInt64, wantRandomAccess: Bool) -> Data {
        // flags: PCR present (0x10) [+ random access indicator 0x40 on keyframe]
        var flags: UInt8 = 0x10
        if wantRandomAccess { flags |= 0x40 }
        var af = Data()
        af.append(0)          // length placeholder
        af.append(flags)
        // 33-bit PCR base (90kHz) + 6 reserved + 9-bit extension (0).
        let base = pcr90k & 0x1_FFFF_FFFF
        af.append(UInt8((base >> 25) & 0xFF))
        af.append(UInt8((base >> 17) & 0xFF))
        af.append(UInt8((base >> 9) & 0xFF))
        af.append(UInt8((base >> 1) & 0xFF))
        af.append(UInt8(((base & 0x1) << 7) | 0x7E))  // reserved bits set
        af.append(0x00)
        af[0] = UInt8(af.count - 1)  // adaptation_field_length excludes itself
        return af
    }

    private func stuffingAdaptation(bytes: Int) -> Data {
        // bytes >= 1. adaptation_field_length + flags(0) + (bytes-2) stuffing.
        var af = Data()
        let total = max(1, bytes)
        af.append(UInt8(total - 1))   // length
        if total >= 2 {
            af.append(0x00)           // flags
            if total > 2 { af.append(contentsOf: [UInt8](repeating: 0xFF, count: total - 2)) }
        }
        return af
    }

    // MARK: - PES

    private func pesPacket(payload: Data, pts90k: UInt64) -> Data {
        var pes = Data([0x00, 0x00, 0x01, 0xE0])  // start code + stream_id (video)
        // PES packet length = 0 (unbounded) for video in TS.
        pes.append(contentsOf: [0x00, 0x00])
        pes.append(0x80)               // marker: '10', no scrambling
        pes.append(0x80)               // PTS present
        pes.append(0x05)               // PES header data length (PTS = 5 bytes)
        // PTS, 33 bits, with marker bits, prefix '0010'.
        let p = pts90k & 0x1_FFFF_FFFF
        pes.append(UInt8(0x21 | ((p >> 29) & 0x0E)))
        pes.append(UInt8((p >> 22) & 0xFF))
        pes.append(UInt8(0x01 | ((p >> 14) & 0xFE)))
        pes.append(UInt8((p >> 7) & 0xFF))
        pes.append(UInt8(0x01 | ((p << 1) & 0xFE)))
        pes.append(payload)
        return pes
    }

    // MARK: - PSI sections (PAT / PMT) with CRC32

    private func patPayload() -> Data {
        var s = Data()
        s.append(0x00)                 // table_id = PAT
        // section_syntax(1)+'0'+reserved '11' + length(12) — fill length after.
        let body: [UInt8] = [
            0x00, 0x01,                // transport_stream_id
            0xC1,                      // reserved '11' + version 0 + current_next 1
            0x00, 0x00,                // section_number, last_section_number
            0x00, 0x01,                // program_number = 1
            0xE0 | UInt8((pmtPID >> 8) & 0x1F), UInt8(pmtPID & 0xFF), // PMT PID
        ]
        let sectionLen = body.count + 4  // + CRC32
        s.append(0xB0 | UInt8((sectionLen >> 8) & 0x0F))
        s.append(UInt8(sectionLen & 0xFF))
        s.append(contentsOf: body)
        s.append(crc32(s))
        return s
    }

    private func pmtPayload() -> Data {
        var s = Data()
        s.append(0x02)                 // table_id = PMT
        var body = Data()
        body.append(contentsOf: [0x00, 0x01])  // program_number
        body.append(0xC1)                       // version/current_next
        body.append(contentsOf: [0x00, 0x00])   // section/last section
        body.append(0xE0 | UInt8((pcrPID >> 8) & 0x1F)); body.append(UInt8(pcrPID & 0xFF)) // PCR_PID
        body.append(contentsOf: [0xF0, 0x00])   // program_info_length = 0
        // one stream: H.264
        body.append(streamType)
        body.append(0xE0 | UInt8((videoPID >> 8) & 0x1F)); body.append(UInt8(videoPID & 0xFF))
        body.append(contentsOf: [0xF0, 0x00])   // ES_info_length = 0
        let sectionLen = body.count + 4          // + CRC32
        s.append(0xB0 | UInt8((sectionLen >> 8) & 0x0F))
        s.append(UInt8(sectionLen & 0xFF))
        s.append(body)
        s.append(crc32(s))
        return s
    }

    // MPEG CRC-32 (poly 0x04C11DB7, init 0xFFFFFFFF, no final xor, MSB-first).
    private func crc32(_ data: Data) -> Data {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : (crc << 1)
            }
        }
        return Data([UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF),
                     UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)])
    }
}

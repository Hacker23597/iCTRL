import Foundation
import CoreMedia

/// Fragmented MP4 (ISO BMFF) muxer for live H.264, targeting browser MSE.
///
/// Emits:
///   - `initSegment()`   → `ftyp` + `moov` (must be sent to every new subscriber
///                          before any fragment). Uses the SPS/PPS bytes captured
///                          from the encoder to build the avcC (avc1 SampleEntry).
///   - `fragment(...)`   → one `moof` + `mdat` per encoded frame. Baseline uses
///                          a fixed 90 kHz timescale and one sample per fragment,
///                          keeping the muxer stateless-per-frame and MSE-friendly.
///
/// Only what a browser <video> needs to demux and hand to the built-in H.264
/// hardware decoder — no audio track, no edit lists, no styp.
final class FMP4Muxer {

    private let timescale: UInt32 = 90_000    // matches TS convention; keeps
                                              // decode/presentation deltas exact.
    private let trackID: UInt32 = 1
    private var sequenceNumber: UInt32 = 1    // moof mfhd counter; browsers
                                              // expect monotonic per fragment.
    private var nextBaseDecodeTime: UInt64 = 0

    private let sps: Data
    private let pps: Data
    let width: Int
    let height: Int

    init?(width: Int, height: Int, sps: Data, pps: Data) {
        guard !sps.isEmpty, !pps.isEmpty, sps.count >= 4 else { return nil }
        self.width = width; self.height = height
        self.sps = sps; self.pps = pps
    }

    /// RFC 6381 codec string derived from the SPS. Format: `avc1.PPCCLL`
    ///   PP = profile_idc          (sps[1])
    ///   CC = constraint_set_flags (sps[2])
    ///   LL = level_idc            (sps[3])
    /// Must be handed to MSE (`addSourceBuffer("video/mp4; codecs=…")`) or
    /// the browser silently rejects the init segment.
    var codecString: String {
        String(format: "avc1.%02X%02X%02X", sps[1], sps[2], sps[3])
    }

    // MARK: - Public API

    /// One-shot init segment (`ftyp` + `moov`). Send to every new subscriber
    /// before any fragment; the browser buffers it and uses it to configure MSE.
    func initSegment() -> Data {
        var d = Data()
        d.append(ftyp())
        d.append(moov())
        return d
    }

    /// A single-sample fragment. `durationTicks` is in the muxer's 90 kHz scale;
    /// pass `UInt32(90_000 / fps)` for evenly spaced frames.
    func fragment(nalus: [Data], durationTicks: UInt32, keyframe: Bool) -> Data {
        // Sample data = one AVCC-formatted access unit: [4-byte length + NAL]…
        var mdatPayload = Data()
        for n in nalus {
            mdatPayload.append(u32be(UInt32(n.count)))
            mdatPayload.append(n)
        }
        let sampleSize = UInt32(mdatPayload.count)
        let baseDecodeTime = nextBaseDecodeTime
        nextBaseDecodeTime &+= UInt64(durationTicks)

        // Build `moof` (metadata) referring to `mdat` right after it.
        let moofData = moof(sequenceNumber: sequenceNumber,
                            baseDecodeTime: baseDecodeTime,
                            sampleSize: sampleSize,
                            sampleDuration: durationTicks,
                            keyframe: keyframe,
                            // trun.data_offset points into the mdat *from moof start*.
                            // We know the layout: moof + mdatHeader(8) + payload,
                            // so the sample begins at moof.count + 8. We patch it
                            // below once moof size is known.
                            trunDataOffsetPlaceholder: true)
        sequenceNumber &+= 1

        // Patch trun.data_offset now that moof is fully built.
        let patched = patchTrunDataOffset(moof: moofData,
                                          dataOffset: Int32(moofData.count + 8 /* mdat header */))
        var out = Data(); out.reserveCapacity(patched.count + 8 + mdatPayload.count)
        out.append(patched)
        out.append(box("mdat", body: mdatPayload))
        return out
    }

    // MARK: - Box builders (ISO/IEC 14496-12 + 14496-15)
    // Each `box("name", body:)` prepends a 4-byte big-endian total size and the
    // 4-char type. All ISO BMFF integers are big-endian.

    private func box(_ type: String, body: Data) -> Data {
        var out = Data(); out.reserveCapacity(8 + body.count)
        out.append(u32be(UInt32(8 + body.count)))
        out.append(type.data(using: .ascii)!)
        out.append(body)
        return out
    }
    private func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, body: Data) -> Data {
        var inner = Data()
        inner.append(version)
        inner.append(u24be(flags))
        inner.append(body)
        return box(type, body: inner)
    }

    // ftyp: brands. `iso5` + `avc1` covers every major browser MSE decoder.
    private func ftyp() -> Data {
        var b = Data()
        b.append("iso5".data(using: .ascii)!)     // major brand
        b.append(u32be(512))                      // minor version
        for brand in ["iso5", "iso6", "avc1", "mp41"] {
            b.append(brand.data(using: .ascii)!)  // compatible brands
        }
        return box("ftyp", body: b)
    }

    // moov = mvhd + trak + mvex
    private func moov() -> Data {
        var b = Data()
        b.append(mvhd())
        b.append(trak())
        b.append(mvex())
        return box("moov", body: b)
    }

    private func mvhd() -> Data {
        var b = Data()
        b.append(u32be(0))              // creation_time
        b.append(u32be(0))              // modification_time
        b.append(u32be(timescale))      // timescale
        b.append(u32be(0))              // duration (0 for fragmented)
        b.append(u32be(0x00010000))     // rate 1.0
        b.append(u16be(0x0100))         // volume 1.0
        b.append(u16be(0))              // reserved
        b.append(Data(repeating: 0, count: 8))                          // reserved [2]
        // 3x3 unity matrix + [0 0 0x40000000]
        for v: UInt32 in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000] {
            b.append(u32be(v))
        }
        b.append(Data(repeating: 0, count: 24))                         // pre_defined [6]
        b.append(u32be(0xFFFF_FFFF))    // next_track_ID (unused for frag)
        return fullBox("mvhd", body: b)
    }

    // trak = tkhd + mdia
    private func trak() -> Data {
        var b = Data()
        b.append(tkhd())
        b.append(mdia())
        return box("trak", body: b)
    }

    private func tkhd() -> Data {
        var b = Data()
        b.append(u32be(0)); b.append(u32be(0))          // creation/modification
        b.append(u32be(trackID))                        // track_ID
        b.append(u32be(0))                              // reserved
        b.append(u32be(0))                              // duration
        b.append(Data(repeating: 0, count: 8))          // reserved [2]
        b.append(u16be(0))                              // layer
        b.append(u16be(0))                              // alternate_group
        b.append(u16be(0))                              // volume
        b.append(u16be(0))                              // reserved
        // matrix
        for v: UInt32 in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000] {
            b.append(u32be(v))
        }
        b.append(u32be(UInt32(width) << 16))            // width  as 16.16
        b.append(u32be(UInt32(height) << 16))           // height as 16.16
        return fullBox("tkhd", flags: 0x000007 /* enabled|inMovie|inPreview */, body: b)
    }

    // mdia = mdhd + hdlr + minf
    private func mdia() -> Data {
        var b = Data()
        b.append(mdhd())
        b.append(hdlr())
        b.append(minf())
        return box("mdia", body: b)
    }

    private func mdhd() -> Data {
        var b = Data()
        b.append(u32be(0)); b.append(u32be(0))          // creation/modification
        b.append(u32be(timescale))                      // timescale
        b.append(u32be(0))                              // duration
        // language: 'und' packed as 3x5-bit ISO-639-2/T
        let und: UInt16 = ((UInt16(0x15) & 0x1F) << 10) | ((UInt16(0x0E) & 0x1F) << 5) | (UInt16(0x04) & 0x1F)
        b.append(u16be(und))
        b.append(u16be(0))                              // pre_defined
        return fullBox("mdhd", body: b)
    }

    private func hdlr() -> Data {
        var b = Data()
        b.append(u32be(0))                              // pre_defined
        b.append("vide".data(using: .ascii)!)           // handler_type
        b.append(Data(repeating: 0, count: 12))         // reserved [3]
        b.append("iCTRL Video\0".data(using: .utf8)!)   // name (null-terminated)
        return fullBox("hdlr", body: b)
    }

    // minf = vmhd + dinf + stbl
    private func minf() -> Data {
        var b = Data()
        b.append(vmhd())
        b.append(dinf())
        b.append(stbl())
        return box("minf", body: b)
    }

    private func vmhd() -> Data {
        var b = Data()
        b.append(u16be(0))                              // graphicsmode
        b.append(Data(repeating: 0, count: 6))          // opcolor [3]
        return fullBox("vmhd", flags: 1, body: b)
    }

    private func dinf() -> Data {
        // A dref with a single "self-contained" url entry — all data is in this file.
        var url = Data()
        // dref inner is: entry_count u32 + entries.
        var dref = Data()
        dref.append(u32be(1))                           // entry_count
        // url_ entry: fullBox with flag 1 = self-contained
        dref.append(fullBox("url ", flags: 1, body: Data()))
        url.append(fullBox("dref", body: dref))
        return box("dinf", body: url)
    }

    // stbl = stsd (avc1 with avcC) + stts/stsc/stsz/stco (all empty for fragmented)
    private func stbl() -> Data {
        var b = Data()
        b.append(stsd())
        // Empty tables required by the spec but populated by moof for fragments.
        b.append(fullBox("stts", body: u32be(0)))
        b.append(fullBox("stsc", body: u32be(0)))
        b.append(fullBox("stsz", body: Data([0,0,0,0]) + u32be(0) + u32be(0))) // sample_size=0, sample_count=0
        b.append(fullBox("stco", body: u32be(0)))
        return box("stbl", body: b)
    }

    private func stsd() -> Data {
        var b = Data()
        b.append(u32be(1))                              // entry_count
        b.append(avc1())
        return fullBox("stsd", body: b)
    }

    // avc1 SampleEntry (14496-15). Fixed-size prefix + avcC child box.
    private func avc1() -> Data {
        var b = Data()
        b.append(Data(repeating: 0, count: 6))          // reserved [6]
        b.append(u16be(1))                              // data_reference_index
        // VisualSampleEntry fields
        b.append(u16be(0))                              // pre_defined
        b.append(u16be(0))                              // reserved
        b.append(Data(repeating: 0, count: 12))         // pre_defined [3]
        b.append(u16be(UInt16(width)))
        b.append(u16be(UInt16(height)))
        b.append(u32be(0x00480000))                     // horizresolution 72dpi
        b.append(u32be(0x00480000))                     // vertresolution 72dpi
        b.append(u32be(0))                              // reserved
        b.append(u16be(1))                              // frame_count
        b.append(Data(repeating: 0, count: 32))         // compressorname (32 bytes)
        b.append(u16be(0x0018))                         // depth
        b.append(i16be(-1))                             // pre_defined
        b.append(avcC())
        return box("avc1", body: b)
    }

    // avcC (H.264 configuration record, 14496-15 §5.2.4.1).
    private func avcC() -> Data {
        var b = Data()
        b.append(UInt8(1))                              // configurationVersion
        b.append(sps[1])                                // AVCProfileIndication
        b.append(sps[2])                                // profile_compatibility
        b.append(sps[3])                                // AVCLevelIndication
        b.append(UInt8(0xFF))                           // 6 bits reserved + lengthSizeMinusOne=3
        b.append(UInt8(0xE1))                           // 3 bits reserved + numOfSPS=1
        b.append(u16be(UInt16(sps.count)))
        b.append(sps)
        b.append(UInt8(1))                              // numOfPPS
        b.append(u16be(UInt16(pps.count)))
        b.append(pps)
        return box("avcC", body: b)
    }

    // mvex = mehd + trex — declares this is a fragmented movie.
    private func mvex() -> Data {
        var b = Data()
        b.append(trex())
        return box("mvex", body: b)
    }

    private func trex() -> Data {
        var b = Data()
        b.append(u32be(trackID))                        // track_ID
        b.append(u32be(1))                              // default_sample_description_index
        b.append(u32be(0))                              // default_sample_duration
        b.append(u32be(0))                              // default_sample_size
        b.append(u32be(0))                              // default_sample_flags
        return fullBox("trex", body: b)
    }

    // MARK: - Fragment (moof) — one sample per fragment

    /// Layout: moof(mfhd + traf(tfhd + tfdt + trun))
    /// trun's data_offset is patched in once we know the total moof size.
    private func moof(sequenceNumber: UInt32,
                      baseDecodeTime: UInt64,
                      sampleSize: UInt32,
                      sampleDuration: UInt32,
                      keyframe: Bool,
                      trunDataOffsetPlaceholder: Bool) -> Data {
        var moofBody = Data()
        moofBody.append(mfhd(sequenceNumber: sequenceNumber))
        moofBody.append(traf(baseDecodeTime: baseDecodeTime,
                             sampleSize: sampleSize,
                             sampleDuration: sampleDuration,
                             keyframe: keyframe))
        return box("moof", body: moofBody)
    }

    private func mfhd(sequenceNumber: UInt32) -> Data {
        return fullBox("mfhd", body: u32be(sequenceNumber))
    }

    private func traf(baseDecodeTime: UInt64,
                      sampleSize: UInt32,
                      sampleDuration: UInt32,
                      keyframe: Bool) -> Data {
        var b = Data()
        b.append(tfhd())
        b.append(tfdt(baseDecodeTime: baseDecodeTime))
        b.append(trun(sampleSize: sampleSize, sampleDuration: sampleDuration, keyframe: keyframe))
        return box("traf", body: b)
    }

    // tfhd: default-base-is-moof flag (0x020000) so trun offsets are relative
    // to the moof — matches CMAF/MSE expectations.
    private func tfhd() -> Data {
        var b = Data()
        b.append(u32be(trackID))
        return fullBox("tfhd", flags: 0x020000, body: b)
    }

    // tfdt v1: 64-bit decode time.
    private func tfdt(baseDecodeTime: UInt64) -> Data {
        var b = Data()
        b.append(u64be(baseDecodeTime))
        return fullBox("tfdt", version: 1, body: b)
    }

    // trun: one sample, with per-sample duration/size/flags, plus data-offset.
    // flags: 0x000001 data-offset present
    //        0x000004 first-sample-flags-present (used to mark keyframe cleanly)
    //        0x000100 sample-duration
    //        0x000200 sample-size
    private func trun(sampleSize: UInt32, sampleDuration: UInt32, keyframe: Bool) -> Data {
        let flags: UInt32 = 0x000001 | 0x000004 | 0x000100 | 0x000200
        var b = Data()
        b.append(u32be(1))                              // sample_count
        b.append(u32be(0))                              // data_offset (patched)
        // first-sample flags: is_leading=0, depends_on: 2 if keyframe / 1 if not,
        // is_depended_on=0, has_redundancy=0, is_non_sync_sample: 0 if key / 1 if not.
        let dependsOn: UInt32 = keyframe ? 2 : 1
        let nonSync: UInt32 = keyframe ? 0 : 1
        let firstFlags: UInt32 = (dependsOn << 24) | (nonSync << 16)
        b.append(u32be(firstFlags))
        b.append(u32be(sampleDuration))
        b.append(u32be(sampleSize))
        return fullBox("trun", flags: flags, body: b)
    }

    /// The trun's data_offset field sits at a fixed spot inside its box. Rather
    /// than track it through construction, locate the trun by scanning boxes
    /// and rewrite the placeholder u32 with the real offset.
    private func patchTrunDataOffset(moof: Data, dataOffset: Int32) -> Data {
        var out = moof
        // moof (8 header) → mfhd (16 total) → traf(header 8 + tfhd 16 + tfdt 16 + trun ...)
        // trun body starts at: 8 (moof) + 16 (mfhd) + 8 (traf) + 16 (tfhd) + 20 (tfdt v1) + 8 (trun hdr) + 4 (fullbox) = 80
        // trun body layout: sample_count(4) | data_offset(4) | first_flags(4) | duration(4) | size(4)
        // So the u32 to patch is at byte 80 + 4 = 84.
        let dataOffsetPos = 84
        precondition(dataOffsetPos + 4 <= out.count, "moof shorter than expected — layout drift")
        let be = UInt32(bitPattern: dataOffset).bigEndian
        withUnsafeBytes(of: be) { raw in
            out.replaceSubrange(dataOffsetPos..<dataOffsetPos + 4, with: raw)
        }
        return out
    }

    // MARK: - Big-endian helpers

    private func u16be(_ v: UInt16) -> Data { var b = v.bigEndian; return Data(bytes: &b, count: 2) }
    private func u24be(_ v: UInt32) -> Data { Data([UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    private func u32be(_ v: UInt32) -> Data { var b = v.bigEndian; return Data(bytes: &b, count: 4) }
    private func u64be(_ v: UInt64) -> Data { var b = v.bigEndian; return Data(bytes: &b, count: 8) }
    private func i16be(_ v: Int16)  -> Data { var b = v.bigEndian; return Data(bytes: &b, count: 2) }
}

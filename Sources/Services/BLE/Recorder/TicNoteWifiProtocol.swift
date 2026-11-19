import Foundation


// MARK: - cmder table

/// Merged table of `WifiProtocol.WifiRequest` / `WifiResponse`.
///
/// ⚠️ This uses `static let` rather than a Swift enum for two reasons, neither of them taste:
///   1. **`3` and `12` have different directions but the same number** (`3` is called PONG on the request side and PING on the response side;
///      `12` is called FILE_SYNC on the request side and FILE_SYNC_STATUS on the response side). Swift enums do not allow duplicate rawValues.
///   2. `0x11 / 0x13 / 0x14` (16/18/19/20) are **not in the interface constant table**,
///      and are only built in `WifiPlugin` —— an enum would give the false impression that "this is everything".
enum TicNoteWifiCmder {

    // ── Same name and number in both directions (semantics differ by direction) ─────────────────────────
    /// Card → phone: error
    static let universalError: UInt16 = 0
    /// Phone → card: handshake reply (answers the card's SAY_HELLO)
    static let handshake: UInt16 = 1
    /// Card → phone: **the first message the card sends after connecting** (`"received devices request hand!"`)
    static let sayHello: UInt16 = 2
    /// Card → phone = PING; phone → card = PONG. **The direction is reversed**, don't mix them up.
    static let heartbeat: UInt16 = 3
    /// Phone → card: turn off Wi-Fi (`{"status":1}`); card → phone is likewise a wrap-up notification
    static let wifiClose: UInt16 = 4
    /// Card → phone: notice
    static let tips: UInt16 = 5
    /// Phone → card: fetch file list; card → phone: list reply (json + bin)
    static let getFileList: UInt16 = 11
    /// Phone → card: start sync (V1); card → phone: sync status (`{"status":…}`)
    static let fileSync: UInt16 = 12
    /// Card → phone: file content chunk (json + bin) —— **the backbone of downloading**
    static let fileSyncContent: UInt16 = 13
    /// Phone → card: delete file (`{"session","scene"}`)
    static let fileDelete: UInt16 = 14
    /// Phone → card: stop sync; card → phone: stop receipt (`{"status":0}` means resuming may continue)
    static let fileSyncStop: UInt16 = 15
    /// Phone → card: OTA push (`{"uid","from","to","size","crc"}`)
    static let otaFile: UInt16 = 16
    /// Phone → card: OTA data chunk (`{"offset","length"}` + bin)
    static let otaData: UInt16 = 18

    static let downFileListV2: UInt16 = 19
    /// Phone → card: fetch file list (V2)
    static let getFileListV2: UInt16 = 20
    static let speedTest: UInt16 = 100
    static let getLog: UInt16 = 101

    /// A few that are not in the interface constant table and only appear in `WifiPlugin`.
    /// They are listed here to make "values outside the table" **visible** —— when you see them in logs, don't assume you misread.
    static let declaredOnlyInPlugin: Set<UInt16> = [16, 18, 19, 20]
}

// MARK: - Frame (a line-by-line implementation of `com.mobvoi.wifi_plugin.socket.WifiDataVo`)

struct TicNoteWifiFrame: Equatable {

    var version: UInt8
    var cmder: UInt16
    /// nil and the empty string are equivalent (officially it is `jsonStr == null` or `trim().isEmpty()`)
    var json: String?
    var bin: Data?

    init(cmder: UInt16, json: String? = nil, bin: Data? = nil, version: UInt8 = 1) {
        self.version = version
        self.cmder = cmder
        self.json = json
        self.bin = bin
    }

    /// Hand-written `==`: **deliberately does not compare `declaredLength`**.
    /// It is the "length the peer claims", which is diagnostic information and plays no part in deciding "are these two the same frame" ——
    /// otherwise "construct a frame vs decode a frame" in the self-check would never be equal (the former never went through the decode path).
    static func == (lhs: TicNoteWifiFrame, rhs: TicNoteWifiFrame) -> Bool {
        lhs.version == rhs.version && lhs.cmder == rhs.cmder
            && lhs.json == rhs.json && lhs.bin == rhs.bin
    }

    // MARK: Encoding

    func encoded() -> Data {
        var body = Data()
        body.append(version)
        body.append(UInt8(cmder & 0xFF))
        body.append(UInt8((cmder >> 8) & 0xFF))

        // See quirk 1 in the type comment: with empty json even the length field is not written.
        let jsonBytes = (json?.isEmpty == false) ? Data(json!.utf8) : nil
        if let jb = jsonBytes {
            body.append(UInt8(jb.count & 0xFF))
            body.append(UInt8((jb.count >> 8) & 0xFF))
            body.append(jb)
        }
        if let bin, !bin.isEmpty {
            body.append(bin)
        }

        let total = body.count + 3
        var out = Data()
        out.append(UInt8(total & 0xFF))
        out.append(UInt8((total >> 8) & 0xFF))
        out.append(UInt8((total >> 16) & 0xFF))
        out.append(body)
        return out
    }

    // MARK: Decoding

    /// Equivalent to `WifiDataVo.init(byte[])` —— **but with one deliberate deviation**, see below.
    ///
    /// It **does not validate** whether `totalLen` matches the actual length (the official code doesn't either),
    /// but records the mismatch in `declaredLength`, so callers can see "the peer miscounted" in logs.
    ///
    /// ## ⚠️ Deliberate deviation: the official decoder drops the bin on a frame "with bin but without json"
    ///
    /// The official bin length is `(totalLen - 8) - jsonLen`. That `8` assumes
    /// **the header is always 8 bytes** (including the jsonLen field). But when json is empty `toWriteData`
    /// **does not write the jsonLen field at all**, and the header is then only 6 bytes. As a result:
    ///
    /// ```
    /// Encoded:  09 00 00 01 0D 00 AA BB CC        (cmder 13, bin = AA BB CC, no json)
    /// Official decode: jsonLen = u16(bytes[6..7]) = 0xBBAA = 48042   ← what it read is the first two payload bytes
    ///         binLen = (9 - 8) - 48042 = negative → the whole bin is dropped
    /// ```
    /// That is, **the official code can encode it but cannot decode it back**. This is not our guess: in self-check §20
    /// there is a reference implementation (`officialDecode`) copied line by line from the official `init`,
    /// which gives `bin == nil` for this frame while ours gives the correct 3 bytes —— the difference is pinned by an assertion.
    ///
    /// **Why we dare to deviate**: the deviation only takes effect on inputs where "the official code necessarily loses data".
    /// The criterion is "is the jsonLen field trustworthy" (`jsonLen>0 && jsonLen+8 <= actual length && jsonLen <= totalLen-8`);
    /// every frame that passes this check takes a path **byte-for-byte identical** to the official one.
    /// In other words: for frames the official code can decode, we agree with it exactly (the self-check compared 5 frames field by field);
    /// for frames it cannot decode, we give the correct result instead of silently dropping data.
    ///
    /// Real-world impact: the frames the card sends with a bin (11/20 list, 13 content, 18 OTA) **all carry json too**,
    /// so this deviation does not change any real behavior under the current protocol —— it guards against "some future firmware
    /// sending a bin-only frame". In that case, copying the official code would produce the symptom "the file comes out as 0 bytes,
    /// but the state machine says the transfer succeeded", which is very hard to track down.
    static func decode(_ data: Data) throws -> TicNoteWifiFrame {
        let b = [UInt8](data)
        guard b.count >= 6 else {
            throw RecorderLinkError.malformed("WifiDataVo needs ≥ 6 B, got \(b.count)")
        }
        let declared = Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16)
        let version = b[3]
        // Quirk 2: low 7 bits. Copies `(bArr[5] & UByte.MAX_VALUE) << 8) + (bArr[4] & UByte.MAX_VALUE)`.
        let cmder = UInt16(b[5] & 0x7F) << 8 | UInt16(b[4] & 0x7F)

        // Whether the jsonLen field itself is trustworthy (see the method comment). Untrustworthy = this frame has no json segment.
        var jsonLen = 0
        var json: String?
        if b.count >= 8 {
            let candidate = Int(b[6]) | (Int(b[7]) << 8)
            let room = declared - 8            // how much json + bin can occupy in total per the declaration
            if candidate > 0, candidate + 8 <= b.count, candidate <= room {
                jsonLen = candidate
                json = String(decoding: b[8..<(8 + candidate)], as: UTF8.self)
            }
        }

        // The header length depends on **whether the jsonLen field exists**: 8 = yes, 6 = no.
        // The official code hard-codes this 6/8 difference as 8, which is the source of the bug above.
        let headerLen = json != nil ? 8 : 6
        let payloadLen = min(declared - headerLen - jsonLen, b.count - headerLen - jsonLen)

        var bin: Data?
        if payloadLen > 0 {
            let start = headerLen + jsonLen
            bin = Data(b[start..<(start + payloadLen)])
        }

        var frame = TicNoteWifiFrame(cmder: cmder, json: json, bin: bin, version: version)
        frame.declaredLength = declared
        return frame
    }

    /// The total length the peer claims. For diagnostics only (see the `decode` comment).
    private(set) var declaredLength: Int = 0

    var bodyByteCount: Int { encoded().count }
}

// MARK: - JSON

/// A minimal JSON generator.
///
/// ## Why hand-written instead of `JSONSerialization`
/// `JSONSerialization` does not guarantee key order. And this project's self-check is **byte-by-byte**
/// (the 353 requests in §18 are pinned that way), so with unstable key order bytes cannot be asserted.
///
/// ## Key order follows fastjson's default behavior
/// The official code uses `com.alibaba.fastjson.JSONObject`, whose `MapSerializer` by default carries
/// `SerializerFeature.MapSortField` → keys are output in alphabetical order.
///
/// ⚠️ **But key order actually doesn't matter**: the peer also parses with fastjson, and dictionary semantics ignore order.
/// Sorting here is purely to make the output **reproducible**, so the self-check can assert whole-frame bytes.
/// That is, if it turns out the official code doesn't sort, change this one spot; correctness is unaffected —— this is also noted in the self-check comments.
enum TicNoteWifiJSON {

    enum Value: Equatable {
        case int(Int64)
        case text(String)
        case flag(Bool)
    }

    static func object(_ fields: [String: Value]) -> String {
        let body = fields.keys.sorted().map { key in
            "\"\(escape(key))\":\(literal(fields[key]!))"
        }.joined(separator: ",")
        return "{\(body)}"
    }

    static func array(_ items: [String]) -> String {
        "[" + items.joined(separator: ",") + "]"
    }

    private static func literal(_ v: Value) -> String {
        switch v {
        case .int(let n):   return String(n)
        case .flag(let b):  return b ? "true" : "false"
        case .text(let s):  return "\"\(escape(s))\""
        }
    }

    /// Only handles the escapes JSON requires. Quotes/backslashes may appear in credentials; everything else goes through as-is.
    /// Control characters are emitted as `\u00XX`, consistent with fastjson.
    private static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}


enum TicNoteWifiOutbound {

    /// Handshake reply (`WifiPlugin.java:1045-1053`, sent on receiving `cmder == 2`).
    ///
    /// `stamp` is `System.currentTimeMillis() / 1000` officially (**seconds**, not milliseconds ——
    /// in the official code it is `/ MSG_ON_MESSAGE` with `MSG_ON_MESSAGE = 1000`; that constant name is a trap).
    static func handshake(token: String, stamp: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.handshake,
            json: TicNoteWifiJSON.object(["token": .text(token), "stamp": .int(stamp)])
        )
    }

    /// Heartbeat PONG. **No json, no bin** → the whole frame is `3 + 3 = 6` bytes
    /// (which is this format's **minimum legal length**; the check at the official decode entry is an error on `< 6`).
    /// Officially the same reused `WifiDataVo(3)` is sent repeatedly (`WifiPlugin.java:1055-1060`).
    static func heartbeatPong() -> TicNoteWifiFrame {
        TicNoteWifiFrame(cmder: TicNoteWifiCmder.heartbeat)
    }

    /// Fetch file list V1 (`WifiPlugin.java:442-459`). ★★ **This is the one the main flow uses.**
    ///
    /// ⚠️ The **semantics** of the three fields `uid` / `single` / `start` are still unconfirmed (the Java side just stuffs
    /// the three `Integer`s passed in from Dart into the JSON as-is). So no defaults are given here either ——
    /// the caller must always supply the values explicitly, and the **only evidence-backed values** are
    /// `TicNoteWifiListRequest.official*` (that one spot has a disassembly source).
    /// That is the temptation of defaults: they disguise "don't know" as "know".
    static func getFileList(uid: Int64, start: Int64, single: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.getFileList,
            json: TicNoteWifiJSON.object([
                "uid": .int(uid), "start": .int(start), "single": .int(single),
            ])
        )
    }

    static func getFileListV2(uid: Int64, start: Int64, single: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.getFileListV2,
            json: TicNoteWifiJSON.object([
                "uid": .int(uid), "start": .int(start), "single": .int(single),
            ])
        )
    }

    /// Start sync V1 (`WifiPlugin.java:864-870`). **Resuming also uses it** (`sendResumeDownloadRequest`).
    /// No `fileType`.
    static func fileSync(session: Int64, scene: Int64, start: Int64, end: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.fileSync,
            json: TicNoteWifiJSON.object([
                "session": .int(session), "scene": .int(scene),
                "start": .int(start), "end": .int(end),
            ])
        )
    }

    /// Start download V2 (`WifiPlugin.java:518-525`): one more `fileType` than V1.
    ///
    /// The newer official version uses this one (`downFileListV2`); V1 (`downFileList`) is kept for older firmware.
    static func downFileListV2(session: Int64, scene: Int64, start: Int64,
                              end: Int64, fileType: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.downFileListV2,
            json: TicNoteWifiJSON.object([
                "session": .int(session), "scene": .int(scene), "start": .int(start),
                "end": .int(end), "fileType": .int(fileType),
            ])
        )
    }

    /// Delete file (`WifiPlugin.java:892-896`).
    static func fileDelete(session: Int64, scene: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.fileDelete,
            json: TicNoteWifiJSON.object(["session": .int(session), "scene": .int(scene)])
        )
    }

    /// Turn off Wi-Fi (`WifiPlugin.java:911-913`, `{"status":1}`).
    ///
    /// Unlike the BLE path's "stop-charging-style wrap-up", here it is **mandatory to send** ——
    /// if not sent, the card's hotspot stays on and drains power (the official code only calls `releaseWifi()` after receiving `cmder == 4`).
    static func wifiClose() -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.wifiClose,
            json: TicNoteWifiJSON.object(["status": .int(1)])
        )
    }

    static func fileSyncStop(session: Int64, scene: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.fileSyncStop,
            json: TicNoteWifiJSON.object(["session": .int(session), "scene": .int(scene)])
        )
    }
}

// MARK: - Inbound: parsing

/// One file record in the reply to `cmder == 11 / 20`.
///
/// ## The layout is **not guessed** —— read byte by byte from the official Dart disassembly and verified on real hardware
///
/// Real-device sample (2026-10-12): `← cmder=11 json={"uid":0,"status":0,"count":57,"offset":0} bin=570B`
/// → 570 ÷ 57 = **exactly 10 bytes per record**.
///
/// Loop body of `WifiLogic::_parseFileItems`(0x1044904):
/// ```
/// x2  = i * 10                     ; record base address
/// ldrsw  x9,  [data + x5 + x2]     ; ★ i32 @ +0  → sessionId (log string "] sessionId=")
/// ldrsw  x11, [data + x5 + x2+4]   ; ★ i32 @ +4  → fileSize (log string ", fileSize=")
/// ldrsh  x13, [data + x5 + x2+8]   ; ★ i16 @ +8  → prop
/// cmp x13, #2 ; "mp3" else "opus"  ; prop == 2 → mp3
/// ```
/// AArch64 is little-endian, so all three fields are **little-endian**. `ldrsw/ldrsh` sign-extend,
/// but `sessionId` is Unix seconds (< 2^31) and `fileSize` is a byte count, so both are normally positive.
///
/// The JSON segment (`{"uid":0,"status":0,"count":N,"offset":0}`) is **only metadata**;
/// the official code just logs it, and the list itself is entirely in `bin`.
struct TicNoteWifiFileEntry: Equatable {
    let sessionId: UInt32
    let sizeBytes: UInt32
    /// 2 = mp3, any other value = opus (the official code has only this one dichotomy; no further semantics are guessed).
    let prop: Int

    /// The raw value of the official `FileItem`'s `prop` field.
    var fileType: UInt16? { UInt16(truncatingIfNeeded: prop) }
    var isMP3: Bool { prop == 2 }
    /// Start time (seconds) self-reported by the card. `sessionId` is this (same source as the BLE channel).
    var startSeconds: UInt32? { sessionId == 0 ? nil : sessionId }
    var startedAt: Date? {
        startSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

enum TicNoteWifiFileList {

    /// Bytes per record (see the comments of `TicNoteWifiFileEntry`).
    static let recordBytes = 10
    /// `prop == 2` means mp3 (the official `cmp x13, #2` in `_parseFileItems`).
    static let propMP3 = 2

    /// Parses the file list out of `bin` (an array of little-endian 10-byte records); the `json` header is used only for **cross-checking**.
    ///
    /// - Returns: the entry array on success (possibly empty —— meaning "no files on the card");
    ///            `nil` when the shape is not recognised (**not the same thing as an empty array**).
    static func parse(frame: TicNoteWifiFrame) -> [TicNoteWifiFileEntry]? {
        // Official path: the list itself is in bin. When bin is missing/empty, look at count in the JSON header:
        //   count == 0 → really no files (legal, return an empty array)
        //   count != 0 → claims files exist but gives no bin → wrong shape, fail
        guard let bin = frame.bin, !bin.isEmpty else {
            if let count = jsonCount(in: frame.json), count == 0 { return [] }
            return nil
        }

        // ★ The bin length must be a multiple of 10. A remainder means this is not the record format we recognise ——
        //   better to fail than to read misaligned (a misaligned sessionId would request a nonexistent file,
        //   with the symptom "the transfer ends immediately but the file is empty").
        guard bin.count % recordBytes == 0 else { return nil }

        let entries: [TicNoteWifiFileEntry] = stride(from: 0, to: bin.count, by: recordBytes).map {
            TicNoteWifiFileEntry(
                sessionId: bin.subdata(in: $0 ..< $0 + 4).withUnsafeBytes {
                    $0.loadUnaligned(as: UInt32.self)   // little-endian (AArch64 / ARM are both LE)
                },
                sizeBytes: bin.subdata(in: $0 + 4 ..< $0 + 8).withUnsafeBytes {
                    $0.loadUnaligned(as: UInt32.self)
                },
                prop: bin.subdata(in: $0 + 8 ..< $0 + 10).withUnsafeBytes {
                    Int(Int16(truncatingIfNeeded: $0.loadUnaligned(as: Int16.self)))
                }
            )
        }

        // Cross-check: count in the JSON header should equal the record count (both are 57 in the real-device sample).
        // A mismatch is **not** treated as failure —— the official code doesn't look at this number at all; we only put the difference in the log.
        if let count = jsonCount(in: frame.json), count != entries.count {
            TicNoteDiagLog.log(
                "WIFI",
                "List entry count mismatch: json.count=\(count) but bin decoded \(entries.count) entries"
                + " (bin \(bin.count)B). Continuing with bin as the source of truth.")
        }
        return entries
    }

    /// `count` in the JSON header (nil if unreadable; no guessing).
    static func jsonCount(in json: String?) -> Int? {
        guard let json, !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let n = object["count"] as? NSNumber
        else { return nil }
        return n.intValue
    }

    /// For diagnostics: lay out the first few records as hex (for real-device comparison; don't dump it all on a long list).
    static func hexDumpPrefix(_ bin: Data, records: Int = 4) -> String {
        let n = min(bin.count, records * recordBytes)
        guard n > 0 else { return "(empty)" }
        return bin.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ")
            + (bin.count > n ? " …(\(bin.count)B)" : "")
    }
}

/// The `{"status": n}` carried in `cmder == 12 / 15 / 19`. `0` = success.
struct TicNoteWifiStatus: Equatable {
    let raw: Int

    static func parse(frame: TicNoteWifiFrame) -> TicNoteWifiStatus? {
        guard let json = frame.json, !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let n = object["status"] as? NSNumber
        else { return nil }
        return TicNoteWifiStatus(raw: n.intValue)
    }

    var isOK: Bool { raw == 0 }
}

struct TicNoteWifiUniversalError: Equatable {
    /// Command code of the rejected request
    let cmd: UInt16
    /// Card-side reason code (semantics unresolved, passed through only)
    let code: Int

    static func parse(frame: TicNoteWifiFrame) -> TicNoteWifiUniversalError? {
        guard frame.cmder == TicNoteWifiCmder.universalError,
              let json = frame.json, !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                                as? [String: Any],
              let cmd = (object["cmd"] as? NSNumber)?.intValue
        else { return nil }
        return TicNoteWifiUniversalError(
            cmd: UInt16(truncatingIfNeeded: cmd),
            code: (object["code"] as? NSNumber)?.intValue ?? -1
        )
    }

    /// One-line summary for logs/errors.
    var description: String { "card refused cmd \(cmd) (code \(code))" }
}

struct TicNoteWifiContentChunk {
    let json: String?
    let offset: Int?
    let length: Int?
    let data: Data

    static func parse(frame: TicNoteWifiFrame) -> TicNoteWifiContentChunk? {
        guard let data = frame.bin, !data.isEmpty else { return nil }
        var offset: Int?
        var length: Int?
        if let json = frame.json, !json.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
            offset = (object["offset"] as? NSNumber)?.intValue
            length = (object["length"] as? NSNumber)?.intValue
        }
        return TicNoteWifiContentChunk(json: frame.json, offset: offset, length: length, data: data)
    }
}

/// **Parameters** for fetching the file list (the values of the three fields `uid` / `start` / `single`).
///
/// ## Why it is a separate type
/// The semantics of these three fields are **still unresolved** (`WifiPlugin.getFileList` just stuffs the three
/// `Integer`s passed in from Dart into the JSON as-is). Since they cannot be decoded, the only responsible approach is
/// to **copy that official call site byte for byte**, and state clearly "which line was copied".
/// Before that, we filled in values that merely "looked reasonable" (`start: 0` / `single: 1`),
/// which amounted to writing "don't know" as "know".
///
/// ## Disassembly of that official call site (both entry points are byte-identical)
/// ```
/// wifi_logic.dart      _handShakeReturn   0x107b66c
/// recording_logic.dart handShakeReturn    0x1045764
///
///   r16 = "uid"    → StoreField r2->field_f  = this.field_2b
///   r16 = "single" → StoreField r2->field_1b = rZR        ← zero register = 0
///   r16 = "start"  → StoreField r2->field_23 = [pp+0x2cf18] Mint: 0x66350a00
/// ```
/// * `single = 0`: `rZR` is ARM64's zero register, and `stur wzr, [x2, #0x1b]` writes 0.
///   We previously filled in 1 (inferred from the comment "probably only wants one entry"), which had **no basis**.
/// * `start = 0x66350A00 = 1714752000` (measured: at that spot it is a `Mint` constant,
///   not `DateTime.now()`): it is neither the current time nor "the previous entry's sid",
///   so "start from the beginning, so fill in 0" likewise has no basis. **Copy the constant.**
/// * `uid`: initialised to **0** in `WifiLogic`'s constructor via `StoreField r1->field_2b = rZR`,
///   and written nowhere else afterwards → always 0. (The line at `0xe2d62c`.)
enum TicNoteWifiListRequest {

    /// The official hard-coded `start`. `0x66350A00` = 2024-05-03T16:00:00Z.
    static let officialStart: Int64 = 1_714_752_000

    /// The official hard-coded `single` (zero register).
    static let officialSingle: Int64 = 0

    /// The official hard-coded `uid` (set to 0 at construction, never written again).
    static let officialUID: Int64 = 0
}

// MARK: - Connection parameters (delivered by the BLE side; none may be hard-coded)

/// Network endpoint constants. Placed in the protocol layer rather than the transport layer so that **they can be asserted in the command-line self-check**
/// (`TicNoteWifiLink` depends on `NWListener`, which is not in the self-check's compilable set).
enum TicNoteWifiEndpoint {
    /// The official Dart `" Start opening WebSocket: port=8081, uuid="` and Java's
    /// `WifiProtocol.WEB_SOCKET_PORT` both point to 8081.
    ///
    /// ⚠️ After the direction correction, it means **the port we ourselves listen on**, not "the port to connect to" ——
    /// the phone is the server. See the top of this file.
    static let port: UInt16 = 8081
}

struct TicNoteWifiCredentials: Equatable {
    let ssid: String
    /// The `WIFI_CIPHER_NO_PASS` case **exists** (see the three encryption capabilities of `ConnectWifiUtils`),
    /// so an empty password is a legal value and must not be treated as "not obtained".
    let passphrase: String
    /// Card-side server address. **Its meaning changed after the direction correction**: the phone is the server,
    /// so this field is "which address the card tells us can be used to interconnect", not "the address we should connect to".
    /// Kept only for logging and future cross-verification.
    let serverHint: String?
    let serverPort: UInt16?
    let clientHint: String?
    let clientPort: UInt16?

    static let ssidKeys = ["ssid", "wifiSsid", "wifi_ssid", "SSID"]
    static let passKeys = ["passwd", "password", "passWord", "wifiSsidPassword", "psk"]
    static let serverIPKeys = ["serverIp", "wifiServerIp", "ip"]
    static let serverPortKeys = ["serverPort", "wifiServerPort", "port"]
    static let clientIPKeys = ["clientIp", "wifiClientIp"]
    static let clientPortKeys = ["clientPort", "wifiClientPort"]

    /// Decodes the credentials from a BLE event map.
    ///
    /// - Returns: `nil` = **no ssid** (= the card has not opened its hotspot yet / this event is not a Wi-Fi status event).
    ///            An empty ssid also counts as none —— passing an empty SSID to `NEHotspotConfiguration` only yields
    ///            a vague system error.
    static func parse(_ map: [String: Any]) -> TicNoteWifiCredentials? {
        func str(_ keys: [String]) -> String? {
            for key in keys {
                if let s = map[key] as? String { return s }
            }
            return nil
        }
        func port(_ keys: [String]) -> UInt16? {
            for key in keys {
                if let n = map[key] as? NSNumber { return UInt16(truncatingIfNeeded: n.intValue) }
                if let s = map[key] as? String, let n = UInt16(s) { return n }
            }
            return nil
        }
        guard let ssid = str(ssidKeys), !ssid.isEmpty else { return nil }
        return TicNoteWifiCredentials(
            ssid: ssid,
            passphrase: str(passKeys) ?? "",
            serverHint: str(serverIPKeys),
            serverPort: port(serverPortKeys),
            clientHint: str(clientIPKeys),
            clientPort: port(clientPortKeys)
        )
    }

    /// Tries to decode Wi-Fi credentials from a **BLE control frame**.
    ///
    /// The frame is `[type 0x01][cmd u16 LE][payload]`, so skip the 3-byte header
    /// and try to treat the rest as a JSON object. Return `nil` if it can't be decoded —— **do not** search
    /// the whole payload for substrings like `ssid=`: that would treat "the card mentioned an SSID somewhere else" as "the card gave credentials",
    /// then join the hotspot with a made-up password, and finally report an error unrelated to the real cause.
    ///
    /// ⚠️ This path has **no measured sample yet** (see `TicNoteWifiProbe`).
    /// It is "lenient": use it if the shape matches, treat it as not received if not —— it causes no wrong behavior,
    /// it only leaves Wi-Fi fast transfer in the unavailable state.
    static func parseBLEFrame(_ frame: Data) -> TicNoteWifiCredentials? {
        guard frame.count > 3, frame.first == TicNotePacketType.commandResponse.rawValue else {
            return nil
        }
        let payload = frame.dropFirst(3)
        guard !payload.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any]
        else { return nil }
        return parse(object)
    }


    static let hotspotSSIDPrefix = "TicNote-"

    /// SSID = `"TicNote-"` + **last 4 characters of the SN**.
    ///
    /// - Parameter sn: the ASCII SN decoded from the advertised manufacturer data (`TicNoteAdvertisementParser`),
    ///                 real-device sample `S02510YCY36W3N9H`.
    /// - Returns: `nil` = the SN is shorter than 4 characters. **No guessing**: rather than assembling a wrong name and having the system report
    ///            "network not found", keep fast transfer unavailable and state the reason clearly.
    static func hotspotSSID(fromSN sn: String) -> String? {
        guard sn.count >= 4 else { return nil }
        return hotspotSSIDPrefix + String(sn.suffix(4))
    }

    /// WPA2 password = **last 8 characters of the SN**.
    ///
    /// Note this is the **plaintext passphrase** (not a derived PSK) —— `ConnectWifiUtils`'s
    /// `setWpa2Passphrase` takes plaintext, and so does `NEHotspotConfiguration(passphrase:)`.
    static func hotspotPSK(fromSN sn: String) -> String? {
        guard sn.count >= 8 else { return nil }
        return String(sn.suffix(8))
    }

    /// Builds the credentials directly from the SN. **This is the default for fast transfer**, since both values are uniquely determined by the SN.
    ///
    /// Address fields are left empty: after the direction correction (the phone is the server) they are only log hints,
    /// and not having them affects no step of the operation.
    static func from(sn: String) -> TicNoteWifiCredentials? {
        guard let ssid = hotspotSSID(fromSN: sn),
              let psk = hotspotPSK(fromSN: sn)
        else { return nil }
        return TicNoteWifiCredentials(
            ssid: ssid,
            passphrase: psk,
            serverHint: nil,
            serverPort: nil,
            clientHint: nil,
            clientPort: nil
        )
    }
}

// MARK: - Sent at binding time: token and hotspot name (BLE control frame, goes over BLE, not Wi-Fi)

enum TicNoteWifiProvisioning {

    static let officialHotspotSSID = "背夹 c1 pro"

    /// Binding token. The same constant as the token used in the WebSocket handshake
    /// (the default value of `TicNoteWifiLink.Config.token` in `RecorderProtocol`).
    static let bindToken = "1234567890000000"

    /// Payload prefix. The origin of `[1]` is undetermined, see the type comment.
    static let provisionPrefix: [UInt8] = [0x02, 0x01, 0x01]

    /// Number of bytes the token field occupies. In the capture the token is exactly 16 bytes, followed by 9 `0x00`s.
    static let tokenFieldBytes = 16
    /// Padding length after the token and before the SSID length byte.
    static let reservedBytes = 9

    /// Builds the `sendToken` frame: `[0x01][0x01 0x00]` + the payload above.
    ///
    /// The SSID length is taken with `& 0xFF`, the same algorithm as on the Dart side; more than 255 bytes is rejected outright
    /// (rather than build a frame with a mismatched length, refuse here —— the card side has no length check).
    ///
    /// - Parameters:
    ///   - token: defaults to `bindToken`. The fast-transfer flow doesn't need to change it.
    ///   - ssid: **for the fast-transfer flow pass `TicNoteWifiCredentials.hotspotSSID(fromSN:)` explicitly**,
    ///           so the name in this frame matches the hotspot to be joined next (in case the card really does trust it, the two sides won't diverge).
    ///           The default `"Back-clip c1 pro"` is the **real-device original value of the official binding frame**, kept only for regression assertions.
    static func sendTokenFrame(token: String = bindToken,
                               ssid: String = officialHotspotSSID) -> Data? {
        let tokenBytes = Array(token.utf8)
        let ssidBytes = Array(ssid.utf8)
        guard tokenBytes.count <= tokenFieldBytes,
              ssidBytes.count > 0,
              ssidBytes.count <= 0xFF
        else { return nil }

        var payload = Data(provisionPrefix)
        payload.append(contentsOf: tokenBytes)
        // Right-pad the 16-byte token field with zeros, then add `reservedBytes` more zeros.
        payload.append(contentsOf: [UInt8](repeating: 0, count: tokenFieldBytes - tokenBytes.count))
        payload.append(contentsOf: [UInt8](repeating: 0, count: reservedBytes))
        payload.append(UInt8(ssidBytes.count & 0xFF))
        payload.append(contentsOf: ssidBytes)

        var out = Data(capacity: 3 + payload.count)
        out.append(TicNotePacketType.commandResponse.rawValue)   // 0x01
        out.append(UInt8(TicNoteWifiCmder.handshake & 0xFF))     // cmd u16 LE = 0x0001
        out.append(UInt8((TicNoteWifiCmder.handshake >> 8) & 0xFF))
        out.append(payload)
        return out
    }
}

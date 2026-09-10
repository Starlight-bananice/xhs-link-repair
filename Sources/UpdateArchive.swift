import Foundation

/// 检查 ZIP 中央目录和对应本地文件头，解压前拒绝越界路径、符号链接和异常体积。
/// 本项目为单一 Swift App，不需要安装包中的符号链接或 ZIP64。
enum UpdateArchive {
    static func validate(_ data: Data) throws {
        func invalid() -> UpdateFailure { UpdateFailure("安装包格式或路径不正确") }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else { throw invalid() }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            try u16(offset) | u16(offset + 2) << 16
        }
        guard data.count >= 22, data.count <= AppUpdater.maximumArchiveSize else { throw invalid() }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try u32(offset) == 0x06054b50, offset + 22 + (try u16(offset + 20)) == data.count {
                end = offset
                break
            }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw invalid() }
        let count = try u16(end + 10)
        let centralSize = try u32(end + 12)
        let centralStart = try u32(end + 16)
        guard count > 0, count <= 2000, try u16(end + 8) == count,
              centralStart + centralSize == end else { throw invalid() }
        var offset = centralStart
        var totalSize = 0
        var names = Set<String>()
        var localRanges: [Range<Int>] = []
        for _ in 0..<count {
            guard offset + 46 <= end, try u32(offset) == 0x02014b50 else { throw invalid() }
            let flags = try u16(offset + 8)
            let compression = try u16(offset + 10)
            let compressed = try u32(offset + 20)
            let size = try u32(offset + 24)
            let nameLength = try u16(offset + 28)
            let extraLength = try u16(offset + 30)
            let commentLength = try u16(offset + 32)
            let mode = (try u32(offset + 38)) >> 16
            let local = try u32(offset + 42)
            let next = offset + 46 + nameLength + extraLength + commentLength
            guard next <= end, nameLength > 0, nameLength < 4096,
                  flags & 1 == 0, compression == 0 || compression == 8,
                  mode & 0o170000 != 0o120000, try u16(offset + 34) == 0 else { throw invalid() }
            let nameData = data.subdata(in: offset + 46..<offset + 46 + nameLength)
            guard let name = String(data: nameData, encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.contains("\0"), !name.contains("\n"), !name.contains("\r"),
                  !name.split(separator: "/").contains(".."), !name.split(separator: "/").contains("."),
                  [AppUpdater.applicationName, "__MACOSX"].contains(String(name.split(separator: "/").first ?? "")),
                  names.insert(name).inserted else { throw invalid() }
            totalSize += size
            guard totalSize <= 64 * 1024 * 1024,
                  local + 30 <= centralStart, try u32(local) == 0x04034b50,
                  try u16(local + 6) == flags, try u16(local + 8) == compression else { throw invalid() }
            let localNameLength = try u16(local + 26)
            let localExtraLength = try u16(local + 28)
            let bodyStart = local + 30 + localNameLength + localExtraLength
            guard localNameLength == nameLength, bodyStart + compressed <= centralStart,
                  data.subdata(in: local + 30..<local + 30 + localNameLength) == nameData else { throw invalid() }
            if flags & 8 == 0 {
                guard try u32(local + 18) == compressed, try u32(local + 22) == size else { throw invalid() }
            }
            localRanges.append(local..<bodyStart + compressed)
            offset = next
        }
        guard offset == end, names.contains("\(AppUpdater.applicationName)/Contents/Info.plist"),
              names.contains("\(AppUpdater.applicationName)/Contents/MacOS/XHSLinkRepair") else { throw invalid() }
        let ranges = localRanges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<ranges.count where ranges[index].lowerBound < ranges[index - 1].upperBound { throw invalid() }
    }
}

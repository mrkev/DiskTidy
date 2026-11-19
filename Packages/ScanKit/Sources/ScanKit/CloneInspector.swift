import Darwin
import Foundation

/// APFS clone information for a file.
public struct CloneInfo: Sendable, Hashable {
    /// Identifies the data stream; clones that haven't diverged share it.
    public let cloneID: UInt64
    /// The file may share blocks with another file (EF_MAY_SHARE_BLOCKS).
    public let mayShareBlocks: Bool
}

public enum CloneInspector {
    /// Reads ATTR_CMNEXT_CLONEID and ATTR_CMNEXT_EXT_FLAGS via getattrlist(2).
    /// Returns nil on volumes that don't support them (non-APFS) or on error.
    public static func info(for url: URL) -> CloneInfo? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
        let flags = UInt32(truncatingIfNeeded: FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)

        var buffer = [UInt8](repeating: 0, count: 64)
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return buffer.withUnsafeMutableBytes { raw in
                getattrlist(path, &request, raw.baseAddress, raw.count, flags)
            }
        }
        guard status == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> CloneInfo? in
            // Layout: u_int32_t length, attribute_set_t returned (5 x u_int32_t),
            // then the requested attributes in bit order, packed.
            let returnedForkAttrs = raw.loadUnaligned(fromByteOffset: 4 + 4 * 4, as: UInt32.self)
            var offset = 4 + MemoryLayout<attribute_set_t>.size

            var cloneID: UInt64 = 0
            if returnedForkAttrs & UInt32(truncatingIfNeeded: ATTR_CMNEXT_CLONEID) != 0 {
                cloneID = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                offset += 8
            }
            var extFlags: UInt64 = 0
            if returnedForkAttrs & UInt32(truncatingIfNeeded: ATTR_CMNEXT_EXT_FLAGS) != 0 {
                extFlags = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            } else if cloneID == 0 {
                return nil
            }
            return CloneInfo(
                cloneID: cloneID,
                mayShareBlocks: extFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
            )
        }
    }
}

import Darwin
import Foundation

struct APFSAttributes {
    let device: dev_t?
    let privateBytes: Int64?
    let cloneID: UInt64?
    let flags: UInt64?
    let cloneReferences: UInt32?

    private static let realDevice = UInt32(ATTR_CMNEXT_REALDEVID)
    private static let privateSize = UInt32(ATTR_CMNEXT_PRIVATESIZE)
    private static let clone = UInt32(ATTR_CMNEXT_CLONEID)
    private static let extendedFlags = UInt32(ATTR_CMNEXT_EXT_FLAGS)
    private static let references = UInt32(ATTR_CMNEXT_CLONE_REFCNT)

    var sharesAllBlocks: Bool { (flags ?? 0) & UInt64(EF_SHARES_ALL_BLOCKS) != 0 }

    static func read(at path: String, deviceOnly: Bool = false) -> Self? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.forkattr = deviceOnly ? realDevice : privateSize | realDevice | clone | extendedFlags | references
        // getattrlist packs buffer length, returned attributes, then requested fields in bit order.
        return withUnsafeTemporaryAllocation(byteCount: 56, alignment: 8) { bytes in
            let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS)
            guard getattrlist(path, &attributes, bytes.baseAddress, bytes.count, options) == 0 else { return nil }
            let returned = bytes.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            func field<T>(_ bit: UInt32, _ offset: Int, _ type: T.Type) -> T? {
                returned & bit == 0 ? nil : bytes.loadUnaligned(fromByteOffset: offset, as: type)
            }
            if deviceOnly {
                return Self(device: field(realDevice, 24, dev_t.self),
                            privateBytes: nil, cloneID: nil, flags: nil, cloneReferences: nil)
            }
            return Self(device: field(realDevice, 32, dev_t.self),
                        privateBytes: field(privateSize, 24, Int64.self),
                        cloneID: field(clone, 36, UInt64.self),
                        flags: field(extendedFlags, 44, UInt64.self),
                        cloneReferences: field(references, 52, UInt32.self))
        }
    }
}

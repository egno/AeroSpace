import Darwin

/// Returns argv of the process joined with spaces. Uses `sysctl(KERN_PROCARGS2)`.
/// Works without extra permissions for the processes of the same user
func getProcessArgs(pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    if unsafe sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size <= MemoryLayout<Int32>.size { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    if unsafe sysctl(&mib, 3, &buffer, &size, nil, 0) != 0 { return nil }
    return parseProcArgs2(Array(buffer.prefix(size)))
}

/// KERN_PROCARGS2 layout: `int argc`, exec path, NUL padding, `argv[0]` ... `argv[argc - 1]` (NUL separated), env vars
func parseProcArgs2(_ buffer: [UInt8]) -> String? {
    let intSize = MemoryLayout<Int32>.size
    if buffer.count < intSize { return nil }
    let argc = buffer.prefix(intSize).enumerated().reduce(Int32(0)) { acc, it in acc | (Int32(it.element) << (8 * it.offset)) }
    var i = intSize
    // Skip exec path
    while i < buffer.count && buffer[i] != 0 { i += 1 }
    // Skip NUL padding
    while i < buffer.count && buffer[i] == 0 { i += 1 }
    var args: [String] = []
    while args.count < argc && i < buffer.count {
        let start = i
        while i < buffer.count && buffer[i] != 0 { i += 1 }
        args.append(String(decoding: buffer[start ..< i], as: UTF8.self))
        i += 1
    }
    return args.joined(separator: " ")
}

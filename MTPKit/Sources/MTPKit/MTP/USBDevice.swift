import Foundation
import IOKit
import IOUSBHost
import os

/// Thin wrapper over an opened MTP USB interface: finds the PTP/MTP interface,
/// seizes it from the system (`ptpcamerad`), opens the bulk-in / bulk-out /
/// interrupt-in pipes, and exposes blocking bulk read/write used by `MTPSession`.
///
/// Blocking I/O is intentional: `MTPSession` is an actor that serializes all access,
/// and the work runs off the main thread.
public final class USBDevice: @unchecked Sendable {
    public struct Info: Sendable {
        public var vendorID: Int
        public var productID: Int
        public var product: String
        public var bulkOutAddress: Int
        public var bulkInAddress: Int
        public var interruptInAddress: Int?
    }

    static let log = Logger(subsystem: "com.Ricky.Android-File-Transfer", category: "USB")

    private let interface: IOUSBHostInterface
    private let bulkOut: IOUSBHostPipe
    private let bulkIn: IOUSBHostPipe
    private let interruptIn: IOUSBHostPipe?
    public let info: Info

    private init(interface: IOUSBHostInterface, bulkOut: IOUSBHostPipe, bulkIn: IOUSBHostPipe,
                 interruptIn: IOUSBHostPipe?, info: Info) {
        self.interface = interface
        self.bulkOut = bulkOut
        self.bulkIn = bulkIn
        self.interruptIn = interruptIn
        self.info = info
    }

    // MARK: Open

    /// Google's "Android File Transfer" installs a background agent that auto-grabs the
    /// MTP interface the moment a phone connects, fighting us for it. Since this app
    /// replaces it, terminate those processes before we claim the device. No-op if they
    /// aren't installed/running. (We run unsandboxed for personal use, so this is allowed.)
    public static func terminateCompetingClients() {
        for name in ["Android File Transfer Agent", "Android File Transfer"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = [name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    log.info("Terminated competing client: \(name, privacy: .public)")
                }
            } catch {
                log.error("killall \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Find and open the first PTP/MTP interface (class 6, protocol 1). If `seize`,
    /// detach the current kernel owner (e.g. `ptpcamerad`) so we can claim it.
    public static func openFirstMTPInterface(seize: Bool = true) throws -> USBDevice {
        guard let service = findMTPInterfaceService() else { throw MTPError.interfaceNotFound }
        defer { IOObjectRelease(service) }

        let options: IOUSBHostObjectInitOptions = seize ? .deviceSeize : []
        let interface: IOUSBHostInterface
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: options, queue: nil, interestHandler: nil)
        } catch {
            log.error("Open interface failed: \(error.localizedDescription, privacy: .public)")
            throw MTPError.usb("開啟 USB 介面失敗：\(error.localizedDescription)")
        }

        // Parse endpoints from the configuration descriptor.
        let config = interface.configurationDescriptor
        guard let ifaceDesc = IOUSBGetNextInterfaceDescriptor(config, nil) else {
            throw MTPError.usb("取不到介面描述子")
        }

        var bulkOutAddr: Int?
        var bulkInAddr: Int?
        var interruptInAddr: Int?

        var current = UnsafeRawPointer(ifaceDesc).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let ep = IOUSBGetNextEndpointDescriptor(config, ifaceDesc, current) {
            let address = Int(IOUSBGetEndpointAddress(ep))
            let type = IOUSBGetEndpointType(ep)          // 2 = bulk, 3 = interrupt (USB bmAttributes)
            let isIn = (address & 0x80) != 0
            switch (type, isIn) {
            case (2, false): bulkOutAddr = address
            case (2, true): bulkInAddr = address
            case (3, true): interruptInAddr = address
            default: break
            }
            current = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }

        guard let outA = bulkOutAddr, let inA = bulkInAddr else {
            throw MTPError.usb("找不到 bulk 端點（out=\(String(describing: bulkOutAddr)) in=\(String(describing: bulkInAddr))）")
        }

        let bulkOut = try interface.copyPipe(withAddress: outA)
        let bulkIn = try interface.copyPipe(withAddress: inA)
        let interruptIn = interruptInAddr.flatMap { try? interface.copyPipe(withAddress: $0) }

        let info = Info(
            vendorID: intProp(service, "idVendor") ?? -1,
            productID: intProp(service, "idProduct") ?? -1,
            product: strProp(service, "USB Product Name") ?? "Android",
            bulkOutAddress: outA, bulkInAddress: inA, interruptInAddress: interruptInAddr
        )
        log.info("Opened MTP interface out=0x\(String(outA, radix: 16)) in=0x\(String(inA, radix: 16)) intr=\(interruptInAddr.map { "0x" + String($0, radix: 16) } ?? "none", privacy: .public)")
        return USBDevice(interface: interface, bulkOut: bulkOut, bulkIn: bulkIn, interruptIn: interruptIn, info: info)
    }

    // MARK: Bulk I/O

    /// Largest single bulk OUT request. Above ~1 MB some devices (e.g. Pixel 3a) wedge
    /// their USB state machine, so we cap each USB transfer here and loop. This is purely
    /// a transport-layer split within one MTP data phase — invisible to the device.
    static let maxBulkWriteChunk = 256 * 1024

    public func writeBulk(_ data: Data, timeout: TimeInterval = 15) throws {
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.maxBulkWriteChunk, data.count)
            let slice = data.subdata(in: offset..<end)
            let buffer = NSMutableData(data: slice)
            var transferred = 0
            do {
                try bulkOut.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
            } catch {
                throw Self.mapIOError(error)
            }
            if transferred != slice.count {
                Self.log.error("Short bulk write: \(transferred)/\(slice.count)")
            }
            offset = end
        }
    }

    /// Single-shot bulk write (no internal splitting) — one USB transfer for the whole
    /// buffer. Used to test/establish that an MTP data phase must be one sendIORequest.
    public func writeBulkRaw(_ data: Data, timeout: TimeInterval = 60) throws {
        let buffer = NSMutableData(data: data)
        var transferred = 0
        do {
            try bulkOut.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            throw Self.mapIOError(error)
        }
    }

    /// Stream `header` immediately followed by the bytes of `fileURL` as ONE continuous
    /// MTP data phase, split into pipelined bulk segments.
    ///
    /// Memory is bounded two ways, which matters for multi-GB files:
    ///  • the file is memory-mapped and each segment is copied out only when its request
    ///    is issued (never the whole file at once), and
    ///  • at most `maxInFlight` requests are outstanding (a sliding window), so we don't
    ///    allocate tens of thousands of buffers up front.
    /// Keeping several requests in flight preserves the "no inter-segment short packet"
    /// behaviour that a single synchronous-per-segment loop would break.
    func writeDataPhaseStreaming(header: [UInt8], fileURL: URL, segmentSize: Int,
                                 maxInFlight: Int = 8,
                                 onProgress: @escaping @Sendable (Int64) -> Void) throws {
        let mapped = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let fileSize = mapped.count
        let total = header.count + fileSize

        let state = PipelineState()
        let inFlight = DispatchSemaphore(value: maxInFlight)
        let group = DispatchGroup()

        // Build the buffer for the segment covering [start, end) of the logical stream
        // (header occupies the first header.count bytes, file bytes follow).
        func makeBuffer(_ start: Int, _ end: Int) -> NSMutableData {
            let buf = NSMutableData(length: end - start)!
            let dst = buf.mutableBytes
            var cursor = start
            var outOff = 0
            // header portion
            if cursor < header.count {
                let hEnd = Swift.min(end, header.count)
                header.withUnsafeBytes { hp in
                    _ = memcpy(dst + outOff, hp.baseAddress!.advanced(by: cursor), hEnd - cursor)
                }
                outOff += hEnd - cursor
                cursor = hEnd
            }
            // file portion (offset into the file = cursor - header.count)
            if cursor < end {
                let fStart = cursor - header.count
                let fLen = end - cursor
                mapped.withUnsafeBytes { fp in
                    _ = memcpy(dst + outOff, fp.baseAddress!.advanced(by: fStart), fLen)
                }
            }
            return buf
        }

        var sent = 0
        var threwError: Error?
        while sent < total {
            if Task.isCancelled { threwError = TransportError.cancelled; break }
            if let err = state.firstError { threwError = Self.mapIOError(err); break }
            inFlight.wait()  // block until a slot frees up — bounds memory

            let start = sent
            let end = Swift.min(start + segmentSize, total)
            let bytes = end - start
            let buffer = makeBuffer(start, end)
            group.enter()
            do {
                try bulkOut.enqueueIORequest(with: buffer, completionTimeout: 60) { status, _ in
                    let done = state.record(status: status, bytes: bytes)
                    if let done { onProgress(Int64(max(0, done - header.count))) }
                    inFlight.signal()
                    group.leave()
                }
            } catch {
                inFlight.signal()
                group.leave()
                threwError = Self.mapIOError(error)
                break
            }
            sent = end
        }

        let result = group.wait(timeout: .now() + 600)
        if let threwError { throw threwError }
        if result == .timedOut { throw MTPError.deviceStalled }
        if let err = state.firstError { throw Self.mapIOError(err) }
    }

    public func readBulk(maxLength: Int = 512 * 1024, timeout: TimeInterval = 15) throws -> Data {
        guard let buffer = NSMutableData(length: maxLength) else { throw MTPError.usb("配置讀取緩衝失敗") }
        var transferred = 0
        do {
            try bulkIn.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            throw Self.mapIOError(error)
        }
        return (buffer as Data).subdata(in: 0..<transferred)
    }

    /// Classify a raw IOUSBHost error. "Unable to send IO" means the device's USB state
    /// machine is wedged and only a port reset (re-enumeration) recovers it.
    private static func mapIOError(_ error: Error) -> MTPError {
        let ns = error as NSError
        if ns.domain == "IOUSBHostErrorDomain" && ns.code == -536870186 {
            return .deviceStalled
        }
        return .usb(error.localizedDescription)
    }

    /// Read one interrupt packet (events). Timeout must be 0 for interrupt pipes.
    public func readInterrupt(maxLength: Int = 1024) throws -> Data {
        guard let pipe = interruptIn else { throw MTPError.usb("無 interrupt 端點") }
        guard let buffer = NSMutableData(length: maxLength) else { throw MTPError.usb("配置中斷緩衝失敗") }
        var transferred = 0
        try pipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: 0)
        return (buffer as Data).subdata(in: 0..<transferred)
    }

    public func close() {
        interface.destroy()
    }

    // MARK: Recovery

    /// Reset and re-enumerate the USB device (software equivalent of unplug/replug).
    /// Used to recover from a wedged interface ("Unable to send IO"). After this the old
    /// IOService is invalid, so callers must discard their transport and re-discover.
    /// Returns true if a reset was issued.
    @discardableResult
    public static func resetDevice() -> Bool {
        guard let ifaceService = findMTPInterfaceService() else { return false }
        defer { IOObjectRelease(ifaceService) }
        guard let deviceService = parentUSBHostDevice(of: ifaceService) else { return false }
        defer { IOObjectRelease(deviceService) }

        do {
            let device = try IOUSBHostDevice(__ioService: deviceService, options: .deviceSeize,
                                             queue: nil, interestHandler: nil)
            try device.reset()
            device.destroy()
            log.info("Issued USB device reset (re-enumerating)")
            return true
        } catch {
            log.error("USB device reset failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Walk up the IORegistry from an interface service to its owning IOUSBHostDevice.
    private static func parentUSBHostDevice(of service: io_service_t) -> io_service_t? {
        var current = service
        IOObjectRetain(current)
        for _ in 0..<8 {
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                IOObjectRelease(current)
                return nil
            }
            IOObjectRelease(current)
            current = parent
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                return current // caller releases
            }
        }
        IOObjectRelease(current)
        return nil
    }

    // MARK: Discovery helpers

    static func findMTPInterfaceService() -> io_service_t? {
        guard let matching = IOServiceMatching("IOUSBHostInterface") else { return nil }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            let cls = intProp(service, "bInterfaceClass")
            let proto = intProp(service, "bInterfaceProtocol")
            if cls == 6 && proto == 1 { return service } // PTP/MTP; caller releases
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        return nil
    }

    private static func intProp(_ service: io_service_t, _ key: String) -> Int? {
        guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let number = cf as? NSNumber else { return nil }
        return number.intValue
    }

    private static func strProp(_ service: io_service_t, _ key: String) -> String? {
        guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let string = cf as? String else { return nil }
        return string
    }
}

/// Thread-safe accumulator for pipelined transfer completions.
private final class PipelineState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0
    private(set) var firstError: Error?

    /// Records one completion. Returns the new total bytes on success, or nil on error.
    func record(status: Int32, bytes: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if status != 0 {
            if firstError == nil { firstError = NSError(domain: "IOUSBHostErrorDomain", code: Int(status)) }
            return nil
        }
        completed += bytes
        return completed
    }
}

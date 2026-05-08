import Foundation
import IOKit
import IOKit.usb

/// Fires `onChange` whenever a USB device is attached or detached. Used by AppModel
/// to react instantly to phone plug/unplug events instead of polling the ADB device
/// state on a timer.
///
/// IOKit's notification port runs on a CFRunLoop source; we add it to the main
/// run-loop so callbacks land on the main thread and AppModel can update its
/// `@Published` state without dispatch hopping. The monitor must be retained for
/// the lifetime of the subscription — the IOKit C callbacks hold an unsafe pointer
/// to `self`.
final class USBDeviceMonitor {
    private var notifyPort: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    private var detachIterator: io_iterator_t = 0
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        start()
    }

    deinit {
        stop()
    }

    private func start() {
        let notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort = notifyPort else { return }
        self.notifyPort = notifyPort
        IONotificationPortSetDispatchQueue(notifyPort, .main)

        let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        // Attach (kIOMatchedNotification): fires for every USB device that ALREADY
        // matches at registration time, plus every new attach afterward. The initial
        // burst is fine — we coalesce them via the model's single-flight refresh.
        IOServiceAddMatchingNotification(
            notifyPort,
            kIOMatchedNotification,
            matching.copy() as! CFDictionary,
            { (refcon, iterator) in
                let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                monitor.drainAndNotify(iterator)
            },
            opaqueSelf,
            &attachIterator
        )
        drainAndNotify(attachIterator)

        // Detach (kIOTerminatedNotification): one event per device removal.
        IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            matching.copy() as! CFDictionary,
            { (refcon, iterator) in
                let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                monitor.drainAndNotify(iterator)
            },
            opaqueSelf,
            &detachIterator
        )
        drainAndNotify(detachIterator)
    }

    private func stop() {
        if attachIterator != 0 {
            IOObjectRelease(attachIterator)
            attachIterator = 0
        }
        if detachIterator != 0 {
            IOObjectRelease(detachIterator)
            detachIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    /// IOKit requires us to drain the iterator returned with each notification —
    /// otherwise the next notification doesn't fire. Each device object is released
    /// after we've seen it. The callback signals "something changed" rather than
    /// passing the device list; the receiver re-queries `adb devices` for the truth.
    private func drainAndNotify(_ iterator: io_iterator_t) {
        var anyChange = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            anyChange = true
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        if anyChange {
            // Already on main queue (we set it via IONotificationPortSetDispatchQueue).
            onChange()
        }
    }
}

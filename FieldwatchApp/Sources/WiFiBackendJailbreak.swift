//
//  WiFiBackendJailbreak.swift
//  Fieldwatch (target التطبيق)
//
//  JailbreakBackend — مسح Wi‑Fi حقيقي عبر private APIs.
//
//  قواعد ملف الـ handoff التي يلتزم بها هذا الملف:
//    • معزول تمامًا خلف WiFiBackend (لا يعرف بقية التطبيق أنه موجود).
//    • لا يُقدَّم كحل مستقر عالميًا: الرموز والمفاتيح تختلف بين إصدارات iOS،
//      والمكتبات الخاصة غير موثّقة ولا مضمونة.
//    • المسح لازمه صلاحيات خاصة؛ لذا نحمّل الرموز بـ dlopen ونفشل بهدوء
//      (isAvailable = false) بدل أن نُسقط التطبيق على جهاز غير مكسور الحماية.
//
//  يجب التحقق على الجهاز قبل الاعتماد عليه. استخدم probe() أولًا — يطبع
//  المكتبة التي نجحت، الرموز، وأسماء المفاتيح التي رجعت فعلًا من أول نتيجة مسح.
//

import Foundation
import Darwin

final class JailbreakWiFiBackend: WiFiBackend {

    let kind: WiFiBackendKind = .jailbreakPrivate

    var onObservation: ((WiFiScanResult) -> Void)?
    var onScanFinished: ((Int, Bool) -> Void)?

    // MARK: - توقيعات الرموز الخاصة

    private typealias OpenFn  = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    private typealias BindFn  = @convention(c) (UnsafeMutableRawPointer?, NSString) -> Int32
    private typealias ScanFn  = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Unmanaged<CFArray>?>?, CFDictionary?) -> Int32
    private typealias CloseFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    /// مسارات محتملة؛ نجرّبها بالترتيب ونتوقف عند أول نجاح.
    private static let libraryPaths = [
        "/System/Library/PrivateFrameworks/Apple80211.framework/Apple80211",
        "/usr/lib/libApple80211.dylib",
    ]

    /// en0 هو واجهة Wi‑Fi على iPhone. تُجرَّب بالترتيب.
    private var interfaces: [String] = ["en0"]

    private var handle: UnsafeMutableRawPointer?
    private var openFn: OpenFn?
    private var bindFn: BindFn?
    private var scanFn: ScanFn?
    private var closeFn: CloseFn?

    private(set) var isAvailable: Bool = false
    private(set) var loadedPath: String?

    /// آخر مفاتيح ظهرت في نتيجة مسح — للتشخيص على الجهاز (probe).
    private(set) var lastResultKeys: [String] = []

    private var lastScanAt: Date = .distantPast
    private let scanLock = NSLock()

    // MARK: - Lifecycle

    init() {
        isAvailable = loadSymbols()
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    private func loadSymbols() -> Bool {
        if openFn != nil && scanFn != nil { return true }

        for path in Self.libraryPaths {
            guard let h = dlopen(path, RTLD_LAZY) else { continue }
            guard
                let openSym = dlsym(h, "Apple80211Open"),
                let bindSym = dlsym(h, "Apple80211BindToInterface"),
                let scanSym = dlsym(h, "Apple80211Scan")
            else {
                dlclose(h)
                continue
            }

            handle = h
            loadedPath = path
            openFn = unsafeBitCast(openSym, to: OpenFn.self)
            bindFn = unsafeBitCast(bindSym, to: BindFn.self)
            scanFn = unsafeBitCast(scanSym, to: ScanFn.self)
            if let closeSym = dlsym(h, "Apple80211Close") {
                closeFn = unsafeBitCast(closeSym, to: CloseFn.self)
            }
            return true
        }
        return false
    }

    func start() { requestScan(minIntervalMs: 0) }

    func stop() { /* المسح هنا متزامن/فوري؛ لا شيء يتوقف */ }

    // MARK: - المسح

    func requestScan(minIntervalMs: Int) {
        scanLock.lock()
        defer { scanLock.unlock() }

        guard loadSymbols(), let openFn, let bindFn, let scanFn else {
            onScanFinished?(0, false)
            return
        }

        // احترام الحد الأدنى بين المسحات (منطق الحصص الكامل في WifiRadio.kt هو الخطوة I).
        if minIntervalMs > 0 {
            let elapsed = Date().timeIntervalSince(lastScanAt) * 1000
            if elapsed < Double(minIntervalMs) {
                onScanFinished?(0, false)
                return
            }
        }
        lastScanAt = Date()

        var instance: UnsafeMutableRawPointer?
        guard openFn(&instance) == 0, let airport = instance else {
            onScanFinished?(0, false)
            return
        }
        defer { _ = closeFn?(airport) }

        let bound = interfaces.first { bindFn(airport, $0 as NSString) == 0 }
        guard bound != nil else {
            onScanFinished?(0, false)
            return
        }

        var out: Unmanaged<CFArray>?
        let status = withUnsafeMutablePointer(to: &out) { ptr in
            scanFn(airport, ptr, nil as CFDictionary?)
        }
        guard status == 0, let cf = out?.takeUnretainedValue() else {
            onScanFinished?(0, false)
            return
        }

        let rows = unsafeBitCast(cf, to: NSArray.self)
        var count = 0
        var keysLogged = false

        for row in rows {
            guard let dict = row as? [String: Any] else { continue }
            if !keysLogged {
                lastResultKeys = dict.keys.sorted()
                keysLogged = true
            }
            guard let result = makeResult(dict) else { continue }
            count += 1
            onObservation?(result)
        }

        onScanFinished?(count, true)
    }

    // MARK: - تحويل نتيجة المسح إلى WiFiScanResult

    private func makeResult(_ dict: [String: Any]) -> WiFiScanResult? {
        let ssid = stringValue(dict, ["SSID", "ssid", "SSID_STR"])
        let bssid = stringValue(dict, ["BSSID", "bssid"])
        guard ssid != nil || bssid != nil else { return nil }

        let rssi = intValue(dict, ["RSSI", "rssi", "Signal", "signal"]) ?? 0
        let channel = intValue(dict, ["CHANNEL", "channel", "CHANNEL_NUM"])

        // مفتاح الـ IE الخام: أشهر تسمية "IE"؛ وقد يأتي Data/NSData أو CFData.
        var blob: [UInt8]?
        if let data = dataValue(dict, ["IE", "ie", "IE_DATA", "informationElements"]) {
            blob = [UInt8](data)
        }

        return WiFiScanResult(
            bssid: bssid,
            ssid: ssid,
            rssi: rssi,
            channel: channel,
            ieBlob: blob,
            capabilities: stringValue(dict, ["CAPABILITIES", "capabilities", "PRIVACY"]),
            source: .jailbreakPrivate
        )
    }

    private func stringValue(_ dict: [String: Any], _ keys: [String]) -> String? {
        if let v = rawValue(dict, keys) as? String { return v }
        if let data = rawValue(dict, keys) as? Data { return String(decoding: data, as: UTF8.self) }
        return nil
    }

    private func intValue(_ dict: [String: Any], _ keys: [String]) -> Int? {
        if let n = rawValue(dict, keys) as? NSNumber { return n.intValue }
        if let i = rawValue(dict, keys) as? Int { return i }
        if let d = rawValue(dict, keys) as? Double { return Int(d) }
        return nil
    }

    private func dataValue(_ dict: [String: Any], _ keys: [String]) -> Data? {
        if let d = rawValue(dict, keys) as? Data { return d }
        return nil
    }

    private func rawValue(_ dict: [String: Any], _ keys: [String]) -> Any? {
        for k in keys { if let v = dict[k] { return v } }
        let lowered = keys.map { $0.lowercased() }
        for (k, v) in dict where lowered.contains(k.lowercased()) { return v }
        return nil
    }

    // MARK: - تشخيص على الجهاز

    /// شغّل هذا مرة واحدة على الجهاز وسجّل الناتج:
    ///   • هل حمّلت المكتبة؟ أي مسار؟
    ///   • هل نجح المسح؟ كم شبكة؟
    ///   • ما أسماء المفاتيح التي ترجعها النتائج على إصدار iOS عندك؟ (هنا يُضبط اسم مفتاح الـ IE)
    func probe() -> String {
        var lines = [String]()
        lines.append("JailbreakWiFiBackend probe")
        lines.append("isAvailable: \(isAvailable)")
        lines.append("loadedPath: \(loadedPath ?? "nil")")
        lines.append("symbols: open=\(openFn != nil) bind=\(bindFn != nil) scan=\(scanFn != nil) close=\(closeFn != nil)")

        var observed = 0
        let previous = onObservation
        onObservation = { _ in observed += 1 }
        requestScan(minIntervalMs: 0)
        onObservation = previous

        lines.append("networks observed: \(observed)")
        lines.append("first result keys: \(lastResultKeys.isEmpty ? "لا شيء — المسح فشل أو لم تُرجع النتائج" : lastResultKeys.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }
}

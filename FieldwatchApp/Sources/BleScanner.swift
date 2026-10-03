//
//  BleScanner.swift
//  Fieldwatch (target التطبيق — هنا حيث يُسمح بـ CoreBluetooth)
//
//  بديل BleRadio.kt: نفس المبدأ (تجميع Observation من إعلان BLE) لكن بـ CoreBluetooth.
//
//  قيود iOS التي يعالجها هذا الملف بصراحة:
//    • لا يوجد MAC address. iOS يعطي CBPeripheral.identifier — UUID خاص بهذا
//      التطبيق على هذا الجهاز — وللأجهزة ذات العنوان العشوائي يتغير الـ UUID.
//    • لا يمكن قراءة AD structure الخام؛ CoreBluetooth يفكّ الإعلان إلى قاموس،
//      فيُبنى RadioFacts من المفاتيح المتاحة: manufacturer data، service data،
//      txPower، flags. والـ raw IE parsing غير متاح هنا إطلاقًا.
//    • المسح في الخلفية مقيّد جدًا: UIBackgroundModes = bluetooth-central،
//      وبلا AllowDuplicates فعليًا، ومدة الجلسة تحدّدها آبل.
//

import Foundation
import CoreBluetooth
import FieldwatchCore

/// صف واحد في الواجهة الحية. الاسم `BleRow` مقصود: لا نُسمّيه Sighting حتى لا يحجب
/// `FieldwatchCore.Sighting` (نموذج النواة المنقول من Kotlin) داخل وحدة التطبيق.
struct BleRow: Identifiable, Hashable {
    let id: String          // CBPeripheral.identifier (ليس MAC)
    var name: String?
    var rssi: Int
    var serviceUUIDs: [String]
    var uasId: String?
    var lat: Double?
    var lon: Double?
    var heading: Double?
    var speed: Double?
    var altitude: Double?
    var lastSeen: Date
}

final class BleScanner: NSObject, ObservableObject {

    @Published private(set) var sightings: [BleRow] = []
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isScanning = false

    private var central: CBCentralManager!
    private let queue = DispatchQueue(label: "app.fieldwatch.ble")
    private var byId: [String: BleRow] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func start() {
        guard central.state == .poweredOn else { return }
        guard !isScanning else { return }
        isScanning = true
        // AllowDuplicates = true هو ما يجعل التتبع الحي ممكنًا (مصدر حرارة/بطارية:
        // نفس ما تعرفه Fieldwatch على أندرويد في ScanSettings).
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stop() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    func clear() {
        byId.removeAll()
        sights { self.sightings = [] }
    }

    // MARK: - Internal

    private func sights(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }

    /// بناء RadioFacts من advertisementData — نفس دور BleAdParser.kt لكن بالمفاتيح المتاحة على iOS.
    private func facts(from advertisementData: [String: Any]) -> RadioFacts {
        var facts = RadioFacts()

        if let tx = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
            facts.txPowerDbm = tx.intValue
        }
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
            facts.connectable = connectable.boolValue
        }

        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfg.count >= 2 {
            let companyId = Int(mfg[0]) | (Int(mfg[1]) << 8) // little-endian
            facts.mfgRecords = [
                MfgRecord(companyId: companyId, dataHex: mfg.dropFirst(2).fieldwatchHexUpper)
            ]
        }

        if let sd = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            facts.serviceData = sd.map { key, value in
                ServiceDataRecord(uuid: key.uuidString, dataHex: value.fieldwatchHexUpper)
            }
        }

        return facts
    }
}

extension BleScanner: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        sights { self.bluetoothState = state }
        if state == .poweredOn { start() } else { isScanning = false }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let facts = facts(from: advertisementData)
        // نفس مسار أندرويد: OpenDroneId.fromFacts على service data FFFA
        // (وعلى iOS لا يوجد vendor IE، لذا Wi-Fi Remote ID غير ممكن).
        let loc = OpenDroneId.fromFacts(facts)

        let id = peripheral.identifier.uuidString
        var row = byId[id] ?? BleRow(
            id: id,
            name: nil,
            rssi: RSSI.intValue,
            serviceUUIDs: [],
            uasId: nil,
            lat: nil,
            lon: nil,
            heading: nil,
            speed: nil,
            altitude: nil,
            lastSeen: Date()
        )

        row.name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? row.name
        row.rssi = RSSI.intValue
        row.lastSeen = Date()

        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            row.serviceUUIDs = uuids.map(\.uuidString)
        }
        if let uas = loc.uasId { row.uasId = uas }
        if let lat = loc.lat, let lon = loc.lon { row.lat = lat; row.lon = lon }
        if let h = loc.headingDeg { row.heading = h }
        if let s = loc.speedMps { row.speed = s }
        if let a = loc.alt { row.altitude = a }

        byId[id] = row
        let rows = Array(byId.values).sorted { $0.rssi > $1.rssi }
        sights { self.sightings = rows }
    }
}

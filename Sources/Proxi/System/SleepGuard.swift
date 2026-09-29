import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// 系统的防睡眠断言和电源来源，纯函数和 C 接口的薄封装，哪个线程都能用。
enum PowerAssertion {
    /// 断言的名字，「活动监视器 → 能耗 → 防止睡眠」和 pmset -g assertions 里能看到。
    static let name = "Proxi 局域网共享"
    static let details = "PS5 等设备正经这台 Mac 上网，共享关闭后恢复"

    /// 该不该阻止睡眠：想保持，而且接着电源或者允许电池供电时也保持。
    static func shouldHold(wanted: Bool, onBattery: Bool, allowOnBattery: Bool) -> Bool {
        wanted && (!onBattery || allowOnBattery)
    }

    /// 阻止空闲睡眠（显示器照常可以关）。失败返回 nil。
    static func create() -> IOPMAssertionID? {
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionNameKey: name,
            kIOPMAssertionDetailsKey: details,
        ]
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
        guard result == kIOReturnSuccess else {
            Log.error("阻止睡眠失败：IOReturn \(result)")
            return nil
        }
        return id
    }

    static func release(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }

    /// 现在是不是电池供电（没有电池的 Mac 总是接电源）。
    static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    /// 本进程现在持有的断言的名字（测试用）。
    static func currentNames() -> [String] {
        var dictionary: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dictionary) == kIOReturnSuccess,
              let all = dictionary?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let mine = all[NSNumber(value: getpid())] ?? []
        return mine.compactMap { $0[kIOPMAssertionNameKey] as? String }
    }
}

/// 局域网共享开着时不让 Mac 进入空闲睡眠，不然 PS5 这类设备的网会跟着 Mac 一起断。
/// 默认只在接电源时保持，电池供电时放开（免得忘了关把电用光）；合盖睡眠是系统层的事，管不了。只在主线程上用。
@MainActor
final class SleepGuard: ObservableObject {
    enum Status: Equatable {
        case off
        /// 正在阻止空闲睡眠。
        case holding
        /// 想保持，但电池供电，按设置暂停了。
        case pausedOnBattery
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var onBattery = false

    private var assertion: IOPMAssertionID = 0
    private var wanted = false
    private var allowOnBattery = false
    private var powerSource: CFRunLoopSource?

    /// 开始监听电源来源的变化：插拔电源时重新决定。
    func start() {
        onBattery = PowerAssertion.isOnBattery()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let guardian = Unmanaged<SleepGuard>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in guardian.powerSourceChanged() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
        apply()
    }

    func update(wanted: Bool, allowOnBattery: Bool) {
        self.wanted = wanted
        self.allowOnBattery = allowOnBattery
        apply()
    }

    /// 退出前释放（进程结束系统也会收回，这里是让退出流程干净）。
    func release() {
        wanted = false
        apply()
    }

    private func powerSourceChanged() {
        onBattery = PowerAssertion.isOnBattery()
        apply()
    }

    private func apply() {
        let hold = PowerAssertion.shouldHold(wanted: wanted, onBattery: onBattery, allowOnBattery: allowOnBattery)
        if hold, assertion == 0, let id = PowerAssertion.create() {
            assertion = id
            Log.info("共享期间保持唤醒：已阻止空闲睡眠")
        } else if !hold, assertion != 0 {
            PowerAssertion.release(assertion)
            assertion = 0
            Log.info("不再阻止睡眠")
        }
        let updated: Status
        if assertion != 0 {
            updated = .holding
        } else if wanted && onBattery && !allowOnBattery {
            updated = .pausedOnBattery
        } else {
            updated = .off
        }
        if updated != status {
            status = updated
        }
    }
}

import Foundation
import CoreMotion

/// 陀螺仪与加速度计采集器。CoreMotion 在主线程以 60 赫兹回调，写入 PadState；
/// 蓝牙层按设置的发送频率把快照打包成运动报告（编号三）发给主机。
///
/// 说明：CMMotionManager 读取设备运动不需要额外权限弹窗；
/// 真机必须保持前台（本项目不声明后台模式），采集与广播同生命周期。
final class MotionProvider: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var availabilityText = "未检测"

    private let manager = CMMotionManager()
    private let pad: PadState
    private let log: LogStore

    init(pad: PadState, log: LogStore) {
        self.pad = pad
        self.log = log
    }

    /// 按设置开关启停。设置变化与界面出现时都会调用，重复调用安全。
    func apply(enabled: Bool) {
        let available = manager.isDeviceMotionAvailable
        availabilityText = available ? "可用" : "设备不支持"

        if enabled {
            guard available else {
                log.add("设备运动不可用，无法采集陀螺仪与加速度", level: .warn)
                if isActive { stopUpdates() }
                return
            }
            guard !isActive else { return }
            manager.deviceMotionUpdateInterval = 1.0 / 60
            manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
                guard let self, let motion else {
                    if let error {
                        self?.log.add("运动数据回调出错：\(error.localizedDescription)", level: .warn)
                    }
                    return
                }
                // 弧度/秒 转 度/秒
                let rad2deg = 180.0 / Double.pi
                let rate = motion.rotationRate
                // 报告含重力的总加速度，与主机侧倾斜感知一致
                let gravity = motion.gravity
                let user = motion.userAcceleration
                self.pad.setMotion(
                    gyroX: rate.x * rad2deg,
                    gyroY: rate.y * rad2deg,
                    gyroZ: rate.z * rad2deg,
                    accelX: gravity.x + user.x,
                    accelY: gravity.y + user.y,
                    accelZ: gravity.z + user.z
                )
            }
            isActive = true
            log.add("运动采集已开启：陀螺仪 ±2000 度/秒、加速度 ±16G，随输入报告一并发送")
        } else {
            if isActive { stopUpdates() }
        }
    }

    private func stopUpdates() {
        manager.stopDeviceMotionUpdates()
        isActive = false
        pad.resetMotion()
        log.add("运动采集已停止，运动报告归零")
    }
}

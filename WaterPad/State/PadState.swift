import Foundation
import SwiftUI

/// 手柄状态的不可变快照。界面与蓝牙发送层共用这一份数据，避免两套状态不同步。
struct GamepadSnapshot: Equatable {
    var leftX: Double = 0
    var leftY: Double = 0
    var rightX: Double = 0
    var rightY: Double = 0
    var leftTrigger: Double = 0
    var rightTrigger: Double = 0
    var pressed: Set<PadButton> = []
    var hat: HatDirection = .released

    /// 运动传感器数据。陀螺仪单位为度/秒，加速度计单位为 G。
    /// 关闭运动采集时保持为零，此时快照与中性状态相等。
    var gyroX: Double = 0
    var gyroY: Double = 0
    var gyroZ: Double = 0
    var accelX: Double = 0
    var accelY: Double = 0
    var accelZ: Double = 0

    static let neutral = GamepadSnapshot()
}

/// 手柄输入状态。所有手势都在主线程触发，因此本类不做额外加锁；
/// 蓝牙发送队列只接收由快照生成的 Data，不直接访问本对象。
final class PadState: ObservableObject {
    @Published private(set) var snapshot = GamepadSnapshot.neutral

    var isIdle: Bool { snapshot == .neutral }

    func setLeftStick(x: Double, y: Double) {
        snapshot.leftX = clamp(x)
        snapshot.leftY = clamp(y)
    }

    func setRightStick(x: Double, y: Double) {
        snapshot.rightX = clamp(x)
        snapshot.rightY = clamp(y)
    }

    func setLeftTrigger(_ value: Double) {
        snapshot.leftTrigger = clamp01(value)
    }

    func setRightTrigger(_ value: Double) {
        snapshot.rightTrigger = clamp01(value)
    }

    func setButton(_ button: PadButton, isPressed: Bool) {
        if isPressed {
            snapshot.pressed.insert(button)
        } else {
            snapshot.pressed.remove(button)
        }
    }

    func setDpad(dx: Int, dy: Int) {
        snapshot.hat = HatDirection.from(dx: dx, dy: dy)
    }

    /// CoreMotion 在主线程按固定节奏回调，写入陀螺仪（度/秒）与加速度（G）。
    func setMotion(gyroX: Double, gyroY: Double, gyroZ: Double,
                   accelX: Double, accelY: Double, accelZ: Double) {
        snapshot.gyroX = gyroX
        snapshot.gyroY = gyroY
        snapshot.gyroZ = gyroZ
        snapshot.accelX = accelX
        snapshot.accelY = accelY
        snapshot.accelZ = accelZ
    }

    /// 清零运动数据。关闭运动采集时调用，让快照回到中性状态，
    /// 主机侧也能立刻观察到静止读数而不是停在旧值上。
    func resetMotion() {
        setMotion(gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0)
    }

    func reset() {
        snapshot = .neutral
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(-1, value))
    }

    private func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

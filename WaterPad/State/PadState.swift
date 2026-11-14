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

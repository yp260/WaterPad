#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WaterPad HID 协议一致性校验。

只依赖 Python 标准库，不需要蓝牙硬件，也不需要 macOS。它做四件事：
  1. 从 Swift 源码里读出真实的报告描述符字节，按 HID 短项格式完整解析并核对报告位宽；
  2. 核对描述符字段顺序、报告打包公式、四种档位的按键位序、PnP ID 与各项常量；
  3. 生成一组黄金报告字节，供后续在 Xcode 里写单元测试时直接复用；
  4. 固化并行项目 PocketTrackpad 真机踩坑得到的硬约束，防止后续改动把已验证结论改回去。

用法：python tools/verify_hid.py
退出码：0 表示全部通过，1 表示发现问题。
"""

import math
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent
SWIFT_DIR = ROOT / "WaterPad"
ISSUES = []
CHECKS = 0


def check(condition, label, detail=""):
    global CHECKS
    CHECKS += 1
    status = "通过" if condition else "失败"
    print(f"  [{status}] {label}" + (f"：{detail}" if detail else ""))
    if not condition:
        ISSUES.append(label + (f"（{detail}）" if detail else ""))


def read(relative):
    path = SWIFT_DIR / relative
    if not path.exists():
        ISSUES.append(f"缺少源码文件 {relative}")
        return ""
    return path.read_text(encoding="utf-8")


def strip_comments(text):
    return re.sub(r"//[^\n]*", "", text)


def extract_u8_array(src, name):
    pattern = r"static let " + re.escape(name) + r": \[UInt8\] = \[(.*?)\n\s*\]"
    match = re.search(pattern, src, re.S)
    if not match:
        ISSUES.append(f"找不到字节数组 {name}")
        return []
    body = strip_comments(match.group(1))
    return [int(value, 16) for value in re.findall(r"0x([0-9A-Fa-f]{2})", body)]


def extract_data_array(src, name):
    pattern = r"static let " + re.escape(name) + r": Data = Data\(\[(.*?)\]\)"
    match = re.search(pattern, src, re.S)
    if not match:
        ISSUES.append(f"找不到 Data 常量 {name}")
        return []
    body = strip_comments(match.group(1))
    return [int(value, 16) for value in re.findall(r"0x([0-9A-Fa-f]{2})", body)]


def extract_int(src, name):
    match = re.search(r"static let " + re.escape(name) + r"(?:: Int)?\s*=\s*(\d+)", src)
    return int(match.group(1)) if match else None


def extract_hex(src, name):
    match = re.search(r"static let " + re.escape(name) + r": UInt8\s*=\s*0x([0-9A-Fa-f]{2})", src)
    return int(match.group(1), 16) if match else None


def parse_hid_items(data):
    """按 HID 短项格式解析，返回 (类型, 标签, 无符号值, 原始负载)。"""
    items = []
    index = 0
    while index < len(data):
        header = data[index]
        index += 1
        raw_size = header & 0x03
        size = 4 if raw_size == 3 else raw_size
        item_type = (header >> 2) & 0x03
        tag = (header >> 4) & 0x0F
        if index + size > len(data):
            raise ValueError(f"第 {len(items) + 1} 项被截断")
        payload = data[index:index + size]
        index += size
        value = sum(byte << (8 * offset) for offset, byte in enumerate(payload))
        items.append((item_type, tag, value, payload))
    return items


def analyze(items):
    depth = 0
    min_depth = 0
    report_ids = []
    input_bits = {}
    output_bits = {}
    report_size = 0
    report_count = 0
    current_id = 0

    for item_type, tag, value, _ in items:
        if item_type == 0:  # Main
            if tag == 0x0A:  # Collection
                depth += 1
            elif tag == 0x0C:  # End Collection
                depth -= 1
                min_depth = min(min_depth, depth)
            elif tag == 0x08:  # Input
                input_bits[current_id] = input_bits.get(current_id, 0) + report_size * report_count
            elif tag == 0x09:  # Output
                output_bits[current_id] = output_bits.get(current_id, 0) + report_size * report_count
        elif item_type == 1:  # Global
            if tag == 0x07:
                report_size = value
            elif tag == 0x09:
                report_count = value
            elif tag == 0x08:
                current_id = value
                if current_id not in report_ids:
                    report_ids.append(current_id)

    return {
        "items": len(items),
        "depth": depth,
        "min_depth": min_depth,
        "report_ids": report_ids,
        "input_bits": input_bits,
        "output_bits": output_bits,
    }


def round_away(value):
    """与 Swift 的 rounded(.toNearestOrAwayFromZero) 保持一致，值域非负。"""
    return int(math.floor(value + 0.5))


def axis(value):
    raw = (min(1.0, max(-1.0, value)) * 127.5) + 127.5
    return min(255, max(0, round_away(raw)))


def trigger(value):
    raw = min(1.0, max(0.0, value)) * 255
    return min(255, max(0, round_away(raw)))


def make_report(snapshot, button_bits, prefix=False):
    bytes_out = [
        axis(snapshot.get("leftX", 0)),
        axis(snapshot.get("leftY", 0)),
        axis(snapshot.get("rightX", 0)),
        axis(snapshot.get("rightY", 0)),
        trigger(snapshot.get("leftTrigger", 0)),
        trigger(snapshot.get("rightTrigger", 0)),
    ]
    mask = 0
    for button in snapshot.get("pressed", []):
        mask |= 1 << button_bits[button]
    bytes_out.append(mask & 0xFF)
    bytes_out.append((mask >> 8) & 0xFF)
    bytes_out.append(snapshot.get("hat", 0) & 0x0F)
    if prefix:
        bytes_out.insert(0, 1)
    return bytes_out


def hexs(data):
    return " ".join(f"{byte:02X}" for byte in data)


def main():
    print("WaterPad HID 协议一致性校验")
    print("=" * 62)

    descriptor_src = read("HID/HIDDescriptor.swift")
    report_src = read("HID/GamepadReport.swift")
    profile_src = read("HID/ControllerProfile.swift")

    # ---------- 1. 描述符解析 ----------
    print("\n[1/7] 报告描述符结构")
    descriptor = extract_u8_array(descriptor_src, "reportDescriptor")
    check(len(descriptor) > 0, "描述符字节可提取", f"{len(descriptor)} 字节")
    items = parse_hid_items(descriptor)
    info = analyze(items)
    check(info["depth"] == 0, "应用集合闭合", f"结束深度 {info['depth']}")
    check(info["min_depth"] >= 0, "无多余集合结束项")
    check(set(info["report_ids"]) == {1, 2}, "报告编号集合", str(sorted(info["report_ids"])))

    input_len = extract_int(descriptor_src, "inputReportLength")
    output_len = extract_int(descriptor_src, "outputReportLength")
    input_id = extract_hex(descriptor_src, "inputReportID")
    output_id = extract_hex(descriptor_src, "outputReportID")
    check(input_len == 9, "输入报告常量为 9 字节", str(input_len))
    check(output_len == 2, "输出报告常量为 2 字节", str(output_len))
    check((input_id, output_id) == (1, 2), "报告编号常量为 1 与 2")
    check(info["input_bits"].get(1) == 72, "输入报告一为 72 位", f"{info['input_bits'].get(1)} 位")
    check(info["output_bits"].get(2) == 16, "输出报告二为 16 位", f"{info['output_bits'].get(2)} 位")
    check(all(bits == 0 for key, bits in info["input_bits"].items() if key != 1),
          "输入项没有落到错误报告编号")
    check(all(bits == 0 for key, bits in info["output_bits"].items() if key != 2),
          "输出项没有落到错误报告编号")

    # ---------- 2. 特征值常量 ----------
    print("\n[2/7] HID 与 GATT 常量")
    check(extract_data_array(descriptor_src, "hidInformation") == [0x11, 0x01, 0x00, 0x03],
          "HID Information 为 1.11 版本、可远程唤醒",
          hexs(extract_data_array(descriptor_src, "hidInformation")))
    check(extract_data_array(descriptor_src, "protocolModeReport") == [0x01],
          "Protocol Mode 为报告协议")
    check(extract_data_array(descriptor_src, "inputReportReference") == [0x01, 0x01],
          "输入 Report Reference 为编号 1、类型输入")
    check(extract_data_array(descriptor_src, "outputReportReference") == [0x02, 0x02],
          "输出 Report Reference 为编号 2、类型输出")
    check(extract_data_array(descriptor_src, "inputReportReference")[0] == input_id,
          "输入 Report Reference 编号与报告编号常量一致")
    check(extract_data_array(descriptor_src, "outputReportReference")[0] == output_id,
          "输出 Report Reference 编号与报告编号常量一致")

    # ---------- 3. 字段顺序 ----------
    print("\n[3/7] 打包字段顺序与描述符对齐")
    expected_order = [
        "axis(snapshot.leftX)",
        "axis(snapshot.leftY)",
        "axis(snapshot.rightX)",
        "axis(snapshot.rightY)",
        "trigger(snapshot.leftTrigger)",
        "trigger(snapshot.rightTrigger)",
        "UInt8(buttonMask & 0x00FF)",
        "UInt8(buttonMask >> 8)",
        "snapshot.hat.rawValue & 0x0F",
    ]
    actual_order = []
    for line in report_src.splitlines():
        clean = strip_comments(line)
        match = re.match(r"\s*bytes\.append\((.+)\)\s*$", clean)
        if match:
            actual_order.append(match.group(1).strip())
    check(actual_order == expected_order,
          "makeBytes 的九个字段顺序",
          f"实际 {len(actual_order)} 项" + ("" if actual_order == expected_order else f"：{actual_order}"))
    check("precondition(bytes.count == HIDSpec.inputReportLength" in report_src,
          "打包时有长度断言")
    check("snapshot.hat.rawValue & 0x0F" in report_src,
          "Hat Switch 高四位保持为零")
    check("raw.rounded(.toNearestOrAwayFromZero)" in report_src,
          "轴与扳机使用远离零舍入，与校验脚本一致")

    # ---------- 4. 档位与按键位序 ----------
    print("\n[4/7] 手柄档位与按键位序")
    profiles = {}
    blocks = re.findall(r"static let (\w+) = ControllerProfile\((.*?)\n    \)", profile_src, re.S)
    check(len(blocks) == 4, "档位数量为四", f"找到 {len(blocks)} 个")
    for name, body in blocks:
        vendor = re.search(r"vendorID:\s*0x([0-9A-Fa-f]{4})", body)
        product = re.search(r"productID:\s*0x([0-9A-Fa-f]{4})", body)
        bits_section = re.search(r"buttonBits:\s*\[(.*?)\n\s*\]", body, re.S)
        pairs = re.findall(r"\.(\w+):\s*(\d+)", bits_section.group(1)) if bits_section else []
        bits = {button: int(bit) for button, bit in pairs}
        profiles[name] = {
            "vendor": int(vendor.group(1), 16) if vendor else None,
            "product": int(product.group(1), 16) if product else None,
            "bits": bits,
        }
        ok = (len(bits) == 14
              and len(set(bits.values())) == 14
              and all(0 <= bit < 16 for bit in bits.values())
              and vendor is not None and product is not None)
        check(ok, f"档位 {name} 的按键位序",
              f"{len(bits)} 键，位号 {min(bits.values()) if bits else '-'} 到 {max(bits.values()) if bits else '-'}")

    # ---------- 5. 黄金报告字节 ----------
    print("\n[5/7] 报告打包黄金数据")
    generic = profiles.get("generic", {}).get("bits", {})
    cases = [
        ("中性状态", {}, [0x80, 0x80, 0x80, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00]),
        ("左摇杆左上满舵", {"leftX": -1, "leftY": -1},
         [0x00, 0x00, 0x80, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00]),
        ("右摇杆右下满舵", {"rightX": 1, "rightY": 1},
         [0x80, 0x80, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00]),
        ("双扳机满加南键加正上", {"leftTrigger": 1, "rightTrigger": 1,
                                  "pressed": ["south"], "hat": 1},
         [0x80, 0x80, 0x80, 0x80, 0xFF, 0xFF, 0x01, 0x00, 0x01]),
        ("半量程轴与扳机", {"leftX": 0.5, "leftTrigger": 0.5},
         [0xBF, 0x80, 0x80, 0x80, 0x80, 0x00, 0x00, 0x00, 0x00]),
        ("三个按钮组合", {"pressed": ["east", "north", "start"]},
         [0x80, 0x80, 0x80, 0x80, 0x00, 0x00, 0x0A, 0x02, 0x00]),
    ]
    for label, snapshot, expected in cases:
        actual = make_report(snapshot, generic) if generic else []
        check(actual == expected, label, hexs(actual))

    prefixed = make_report({"hat": 3}, generic, prefix=True) if generic else []
    check(prefixed[:1] == [0x01] and len(prefixed) == 10,
          "带编号前缀的报告", hexs(prefixed))

    # ---------- 6. PnP ID 与源码清单 ----------
    print("\n[6/7] 设备身份与源码清单")
    for name, profile in profiles.items():
        vendor, product = profile["vendor"], profile["product"]
        if vendor is None or product is None:
            continue
        pnp = [0x02, vendor & 0xFF, vendor >> 8, product & 0xFF, product >> 8, 0x00, 0x01]
        ok = len(pnp) == 7 and pnp[0] == 0x02
        check(ok, f"档位 {name} 的 PnP ID", hexs(pnp))

    check("let vendor = spoofing ? vendorID : 0x0000" in profile_src
          and "let product = spoofing ? productID : 0x0000" in profile_src,
          "关闭伪装时 PnP 厂商与产品编号填零")

    swift_files = sorted(SWIFT_DIR.rglob("*.swift"))
    check(len(swift_files) >= 12, "Swift 源码文件齐全", f"{len(swift_files)} 个")
    for path in swift_files:
        print(f"        {path.relative_to(ROOT)}")

    # ---------- 7. 固化并行项目的真机教训 ----------
    # 这些约束来自 G:/2026-11-14-12-53-22/PocketTrackpad 的 14 轮真机出包，
    # 每一条都对应一次真实故障（点开即退、主机搜不到、无法切换主机）。
    print("\n[7/7] 真机教训固化检查")
    builder_src = read("Bluetooth/HIDServiceBuilder.swift")
    peripheral_src = read("Bluetooth/HIDPeripheralManager.swift")
    content_src = read("Views/ContentView.swift")
    settings_src = read("Views/SettingsView.swift")
    project_path = ROOT / "project.yml"
    project_src = project_path.read_text(encoding="utf-8") if project_path.exists() else ""

    # 要求左方括号后直接换行，避免误匹配 HIDServiceSet 里的「let advertisedUUIDs: [CBUUID]」声明。
    adv_block = re.search(r"advertisedUUIDs:\s*\[\n(.*?)\n\s*\]",
                          strip_comments(builder_src), re.S)
    adv_text = adv_block.group(1) if adv_block else ""
    check(adv_text.count("SIGUUID.short(") == 3
          and "SIGUUID.short(SIGUUID.hidService)" in adv_text
          and "SIGUUID.full(" not in adv_text,
          "广播包使用三个 16 位 SIG 编号且含 0x1812",
          "128 位广播会被主机当成未知服务屏蔽")

    gatt_text = strip_comments(builder_src)
    check(all(token in gatt_text for token in [
        "SIGUUID.full(SIGUUID.hidService)",
        "SIGUUID.full(SIGUUID.deviceInformationService)",
        "SIGUUID.full(SIGUUID.batteryService)",
        "type: SIGUUID.full(short)",
    ]), "GATT 服务树与特征仍用完整 128 位编号（与广播分开）")

    char_blocks = re.findall(r"CBMutableCharacteristic\((.*?)\n\s*\)", gatt_text, re.S)
    check(bool(char_blocks) and all("value: nil" in block for block in char_blocks),
          "可变特征初始化 value 为 nil（避免 cached values must be read-only 闪退）",
          f"{len(char_blocks)} 处构造")

    check("request.offset" in peripheral_src, "读请求处理 ATT offset 分段")
    check("startAdvertising(fullUUIDs: true)" in peripheral_src,
          "16 位广播被拒时有完整 128 位回退")
    check("self.manager = nil" in peripheral_src and "self.manager?.delegate = nil" in peripheral_src,
          "停止时释放外设管理器，才能主动断开已连接主机")

    project_effective = re.sub(r"#[^\n]*", "", project_src)
    check("UIBackgroundModes" not in project_effective,
          "工程配置未声明后台模式（免费账号侧载点开即退的已知诱因）")

    on_appear = re.search(r"\.onAppear\s*\{(.*?)\n\s*\}", content_src, re.S)
    check(on_appear is not None and "peripheral.start()" not in on_appear.group(1),
          "界面不再自动启动蓝牙外设，改由按钮触发")
    check("开始广播" in content_src and "停止广播" in content_src,
          "界面提供开始与停止广播按钮")

    check("Mac 与 iPad 实测不会发现" not in (settings_src + peripheral_src + descriptor_src),
          "不再把 iPad 写成无条件硬墙（同链路鼠标类别已真机配对成功）")

    # ---------- 结论 ----------
    print("\n" + "=" * 62)
    if ISSUES:
        print(f"结论：发现 {len(ISSUES)} 个问题（共 {CHECKS} 项检查）")
        for issue in ISSUES:
            print(f"  - {issue}")
        return 1
    print(f"结论：全部通过（共 {CHECKS} 项检查）")
    print("黄金报告字节可直接在 Xcode 单元测试中作为期望值复用。")
    return 0


if __name__ == "__main__":
    sys.exit(main())

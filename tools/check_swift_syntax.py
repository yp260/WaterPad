#!/usr/bin/env python3
"""WaterPad Swift 源码的词法级静态检查。

本机没有 Xcode，编译器只能靠 CI 跑 macOS runner。这个脚本负责抓那些
「括号不平衡 / 字符串没闭合 / 结构体成员漏写」的低级错误，
在推代码之前先拦一道，避免浪费一次 CI 出包。

检查项：
  1. 括号配对（() [] {}），忽略字符串与注释内容；
  2. 字符串字面量与注释是否闭合；
  3. 常见 API 误用（本项目自定义规则）。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "WaterPad"

PAIRS = {")": "(", "]": "[", "}": "{"}
OPENERS = set(PAIRS.values())


def strip_code(src: str) -> str:
    """去掉字符串字面量与注释，只留下代码骨架，避免误报括号。"""
    out = []
    i = 0
    n = len(src)
    in_string = False
    in_multiline = False
    in_line_comment = False
    in_block_comment = False
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
                out.append("\n")
            i += 1
            continue
        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 2
                continue
            if ch == "\n":
                out.append("\n")
            i += 1
            continue
        if in_multiline:
            if ch == '"' and nxt == '"' and (i + 2 < n and src[i + 2] == '"'):
                in_multiline = False
                i += 3
                continue
            if ch == "\n":
                out.append("\n")
            i += 1
            continue
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
                i += 1
                continue
            if ch == "\n":
                # 普通字符串不能跨行，出现即为未闭合
                raise ValueError(f"字符串未闭合，行 {src[:i].count(chr(10)) + 1}")
            i += 1
            continue
        # 不在字符串里
        if ch == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block_comment = True
            i += 2
            continue
        if ch == '"':
            if nxt == '"' and (i + 2 < n and src[i + 2] == '"'):
                in_multiline = True
                i += 3
                continue
            in_string = True
            i += 1
            continue
        out.append(ch)
        i += 1
    if in_string or in_block_comment or in_multiline:
        raise ValueError("存在未闭合的字符串或块注释")
    return "".join(out)


def check_balance(path: Path) -> list[str]:
    problems: list[str] = []
    try:
        code = strip_code(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        return [f"{exc}"]
    stack: list[tuple[str, int]] = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
            continue
        if ch in OPENERS:
            stack.append((ch, line))
        elif ch in PAIRS:
            if not stack:
                problems.append(f"多余右括号 {ch}（第 {line} 行）")
                break
            opener, opened_line = stack.pop()
            if opener != PAIRS[ch]:
                problems.append(
                    f"括号不匹配：第 {opened_line} 行的 {opener} 与第 {line} 行的 {ch}"
                )
                break
    if stack and not problems:
        opener, opened_line = stack[-1]
        problems.append(f"未闭合的括号 {opener}（第 {opened_line} 行）")
    return problems


# 项目自定义规则：(文件相对路径, 必须出现的正则, 说明)
RULES: list[tuple[str, str, str]] = [
    ("Views/GamepadView.swift", r"DragGesture\(minimumDistance:\s*0", "拖拽手势必须 minimumDistance 0，否则轻点无法选中控件"),
    ("Views/GamepadView.swift", r"MagnificationGesture", "缺少捏合缩放手势"),
    ("Views/GamepadView.swift", r"coordinateSpace\(name:", "缺少命名坐标系，拖动会抖动"),
    ("Views/GamepadView.swift", r"persistLayout\(\)", "布局改动没有持久化"),
    ("Views/LayoutEditorPanel.swift", r"ForEach\(ControlID\.allCases\)", "面板缺少按名称选择控件的列表"),
    ("Views/LayoutEditorPanel.swift", r"\\\.x", "面板缺少 X 位置调节"),
    ("Views/LayoutEditorPanel.swift", r"\\\.y", "面板缺少 Y 位置调节"),
    ("Views/LayoutEditorPanel.swift", r"\\\.scale", "面板缺少大小调节"),
    ("State/PadLayout.swift", r"var displayName: String", "控件缺少中文名，选择器无法按名字索引"),
    ("State/PadLayout.swift", r"PadLayout\.default\[id\]", "缺项没有回退到默认布局"),
]


def main() -> int:
    if not ROOT.exists():
        print(f"找不到源码目录：{ROOT}")
        return 2

    swift_files = sorted(ROOT.rglob("*.swift"))
    if not swift_files:
        print("没有找到 Swift 源码")
        return 2

    problems: list[str] = []
    for path in swift_files:
        for issue in check_balance(path):
            problems.append(f"{path.relative_to(ROOT.parent)}: {issue}")

    for rel, pattern, message in RULES:
        target = ROOT / rel
        if not target.exists():
            problems.append(f"{rel}: 文件缺失")
            continue
        if not re.search(pattern, target.read_text(encoding="utf-8")):
            problems.append(f"{rel}: {message}")

    print("=" * 62)
    print(f"检查 {len(swift_files)} 个 Swift 文件")
    if problems:
        print(f"发现 {len(problems)} 个问题：")
        for item in problems:
            print(f"  - {item}")
        return 1
    print("结论：全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())

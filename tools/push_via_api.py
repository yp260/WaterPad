#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Git Data API 推送兜底。

背景：本机网络环境里 git push 走 CONNECT 隧道会被拒绝（502），完全直连也不通，
但 gh api 到 api.github.com 是放行的。因此用 GitHub Git Data API 逐步推送：
blob → tree → commit → 创建 main 引用。

用法：python tools/push_via_api.py [提交信息]
不接参数时提交信息为 "WaterPad: sync via Git Data API"。
用 gh token 更新 ref 会正常触发 push workflow，与 git push 等效。

注意：API 提交与本地提交的 SHA 不同（GitHub 侧重新计算），内容一致。
本地 git 里的改动与远程之间不做 SHA 对齐，以内容为准。
"""

import base64
import json
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent
GH = r"C:/Program Files/GitHub CLI/gh.exe"
REPO = "yp260/WaterPad"


def run_git(*args, binary=False):
    result = subprocess.run(["git", "-C", str(ROOT), *args],
                            capture_output=True)
    if result.returncode != 0:
        print(result.stderr.decode("utf-8", "replace"))
        sys.exit(1)
    return result.stdout if binary else result.stdout.decode("utf-8")


def gh_api(*args, stdin_data=None):
    command = [GH, "api", *args]
    result = subprocess.run(command, capture_output=True,
                            input=(stdin_data.encode("utf-8")
                                   if isinstance(stdin_data, str) else stdin_data))
    if result.returncode != 0:
        print("gh api 调用失败：", args)
        print(result.stdout.decode("utf-8", "replace"))
        print(result.stderr.decode("utf-8", "replace"))
        sys.exit(1)
    text = result.stdout.decode("utf-8")
    return json.loads(text) if text.strip() else {}


def main():
    message = sys.argv[1] if len(sys.argv) > 1 else "WaterPad: sync via Git Data API"

    entries = []
    for line in run_git("ls-tree", "-r", "HEAD").splitlines():
        meta, path = line.split("\t", 1)
        mode, kind, sha = meta.split()
        entries.append({"mode": mode, "type": kind, "sha": sha, "path": path})

    print(f"本地 HEAD 共 {len(entries)} 个文件，开始逐个上传 blob")
    tree_items = []
    for index, entry in enumerate(entries, start=1):
        content = run_git("cat-file", "blob", entry["sha"], binary=True)
        payload = json.dumps({
            "content": base64.b64encode(content).decode("ascii"),
            "encoding": "base64",
        })
        blob = gh_api("-X", "POST", f"repos/{REPO}/git/blobs",
                     "--input", "-", stdin_data=payload)
        tree_items.append({
            "path": entry["path"],
            "mode": entry["mode"],
            "type": "blob",
            "sha": blob["sha"],
        })
        print(f"  [{index}/{len(entries)}] {entry['path']}")

    print("创建 tree")
    tree = gh_api("-X", "POST", f"repos/{REPO}/git/trees", "--input", "-",
                 stdin_data=json.dumps({"tree": tree_items}))

    print("创建 commit")
    parents = []
    refs = gh_api(f"repos/{REPO}/git/refs/heads/main")
    if isinstance(refs, dict) and "object" in refs:
        parents = [refs["object"]["sha"]]
        print(f"  基于远程 main：{parents[0][:10]}")
    commit = gh_api("-X", "POST", f"repos/{REPO}/git/commits", "--input", "-",
                    stdin_data=json.dumps({
                        "message": message,
                        "tree": tree["sha"],
                        "parents": parents,
                    }))

    print("更新 main 引用")
    if parents:
        gh_api("-X", "PATCH", f"repos/{REPO}/git/refs/heads/main", "--input", "-",
               stdin_data=json.dumps({"sha": commit["sha"]}))
    else:
        gh_api("-X", "POST", f"repos/{REPO}/git/refs", "--input", "-",
               stdin_data=json.dumps({"ref": "refs/heads/main",
                                      "sha": commit["sha"]}))

    print(f"完成：main -> {commit['sha']}")
    print(f"仓库页：https://github.com/{REPO}")


if __name__ == "__main__":
    main()

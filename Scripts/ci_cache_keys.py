#!/usr/bin/env python3
"""生成 Actions 缓存键；stdout 可直接追加到 GITHUB_ENV。"""

import hashlib
import json
import os
from pathlib import Path


PACKAGE_ONLY_CONFIG_PREFIXES = (
    "CONFIG_PACKAGE_",
    "CONFIG_DEFAULT_",
    "CONFIG_TARGET_DEVICE_PACKAGES_",
)


def required(name):
    value = os.environ.get(name, "")
    if not value.strip():
        raise SystemExit(f"缓存键缺少必要元数据：{name}")
    return value


def fingerprint(values):
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()


def config_symbol(line):
    if line.startswith("# ") and line.endswith(" is not set"):
        return line[2:-len(" is not set")]
    if line.startswith("#"):
        return ""
    return line.split("=", 1)[0]


def toolchain_config_hash(path):
    normalized = []
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line:
            continue
        symbol = config_symbol(line)
        if not symbol or symbol.startswith(PACKAGE_ONLY_CONFIG_PREFIXES):
            continue
        normalized.append(line)
    content = "\n".join(sorted(normalized)) + "\n"
    return hashlib.sha256(content.encode()).hexdigest()


def main():
    # 镜像版本也参与隔离，避免升级 host 编译器/运行库后复用旧工具。
    scope = {
        name: required(name)
        for name in (
            "RUNNER_OS", "RUNNER_ARCH", "ImageOS", "ImageVersion",
            "WRT_REPO_URL", "WRT_REPO_BRANCH", "DEVICE_TARGET", "DEVICE_SUBTARGET",
        )
    }
    source_hash = required("REPO_GIT_HASH")
    scripts_hash = required("CACHE_SCRIPTS_HASH")
    config = Path(required("OPENWRT_PATH")) / ".config"
    config_hash = toolchain_config_hash(config)
    compatibility_hash = fingerprint({
        **scope,
        "source": source_hash,
        "config": config_hash,
        "scripts": scripts_hash,
    })
    print(f"TOOLCHAIN_CACHE_KEY=toolchain-v3-{compatibility_hash}")
    # ccache 自行验证编译器、源码和参数，可在同一 scope 内跨提交复用。
    print(f"CCACHE_CACHE_PREFIX=ccache-v2-{fingerprint(scope)}")


if __name__ == "__main__":
    main()

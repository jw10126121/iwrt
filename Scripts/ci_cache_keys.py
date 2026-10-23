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
    # 工具链缓存需要和运行环境严格隔离；源码 commit 单独放在精确键的末尾，
    # 这样恢复时可以在同一配置下回退到较早的源码缓存。
    toolchain_scope = {
        name: required(name)
        for name in (
            "RUNNER_OS", "RUNNER_ARCH", "ImageOS", "ImageVersion",
            "WRT_REPO_URL", "WRT_REPO_BRANCH", "DEVICE_TARGET", "DEVICE_SUBTARGET",
        )
    }
    source_hash = required("REPO_GIT_HASH")
    config_label = required("WRT_CONFIG_LABEL")
    config = Path(required("OPENWRT_PATH")) / ".config"
    config_hash = toolchain_config_hash(config)
    stable_scope = {
        name: toolchain_scope[name]
        for name in (
            "RUNNER_OS", "RUNNER_ARCH", "ImageOS", "WRT_REPO_URL",
            "WRT_REPO_BRANCH", "DEVICE_TARGET", "DEVICE_SUBTARGET",
        )
    }
    stable_hash = fingerprint({**stable_scope, "config": config_hash})
    image_hash = fingerprint({"ImageVersion": toolchain_scope["ImageVersion"]})[:16]
    print(f"TOOLCHAIN_CACHE_KEY=toolchain-v4-{stable_hash}-{image_hash}-{source_hash}")
    # ImageVersion 参与恢复前缀；不同 Runner 镜像不要直接复用 host/toolchain 二进制。
    print(f"TOOLCHAIN_CACHE_RESTORE_KEY=toolchain-v4-{stable_hash}-{image_hash}-")

    # ccache 自行验证编译器、源码和参数；Runner 镜像升级不应让已有对象全部失效。
    ccache_scope = {
        name: toolchain_scope[name]
        for name in (
            "RUNNER_OS", "RUNNER_ARCH", "WRT_REPO_URL", "WRT_REPO_BRANCH",
            "DEVICE_TARGET", "DEVICE_SUBTARGET",
        )
    }
    ccache_prefix = f"ccache-v4-{fingerprint(ccache_scope)}"
    print(f"CCACHE_CACHE_PREFIX={ccache_prefix}")
    # run_id 不能出现在精确键中，否则每次运行都只能命中 restore-keys，
    # actions/cache 的 cache-hit 永远是 false。配置标签用于隔离不同设备的缓存。
    print(f"CCACHE_CACHE_KEY={ccache_prefix}-{config_label}")


if __name__ == "__main__":
    main()

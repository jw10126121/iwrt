#!/usr/bin/env python3
"""Common platform identity for firmware and plugin archives."""

import re


PLATFORM_FIELDS = ("source_type", "source_tag", "target", "subtarget", "arch")


def platform_identity(metadata):
    values = tuple(metadata.get(field) for field in PLATFORM_FIELDS)
    for field, value in zip(PLATFORM_FIELDS, values):
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", value) or value in (".", ".."):
            raise ValueError(f"无效的平台标识字段：{field}")
    return values


def platform_archive_name(metadata, kind):
    if kind not in ("firmware", "plugins"):
        raise ValueError(f"无效的平台归档类型：{kind}")
    return "-".join((*platform_identity(metadata), kind)) + ".zip"

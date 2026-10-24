#!/bin/bash
# 说明：
# 1. 在 GitHub Actions 中生成多行通知内容。
# 2. 同时写入 GITHUB_ENV 与 GITHUB_OUTPUT，供后续步骤或 Action 输出复用。

set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

release_tag="${OUTPUT_NAME_PREFIX:-${START_TIME:?START_TIME is required}_${DEVICE_SUBTARGET:?DEVICE_SUBTARGET is required}}"
artifact_url="https://github.com/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}/actions/runs/${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"

get_notify_body() {
    # 通知正文优先使用纯文本版 readme，避免把 Release 专用的 HTML details 标签发到 IM。
    if [ -n "${readme_desc_file:-}" ] && [ -f "${readme_desc_file}" ]; then
        cat "${readme_desc_file}"
        return 0
    fi

    # 纯文本版缺失时，再回退到发布说明，确保至少仍有一份完整正文可用。
    if [ -n "${release_desc_file:-}" ] && [ -f "${release_desc_file}" ]; then
        cat "${release_desc_file}"
        return 0
    fi

    # 编译结束通知运行在 CORE 任务中，发布任务生成的 README 尚不存在。
    # 复用 readme.sh 从最终 .config 生成同格式正文，确保结果通知也包含插件清单。
    if [ -n "${OPENWRT_PATH:-}" ] && [ -f "${OPENWRT_PATH}/.config" ] && \
       [ -n "${GITHUB_WORKSPACE:-}" ] && [ -n "${WRT_DIR_SCRIPTS:-}" ]; then
        local tmp_desc_file
        tmp_desc_file="$(mktemp "${TMPDIR:-/tmp}/notify-desc.XXXXXX.txt")"
        if bash "${GITHUB_WORKSPACE}/${WRT_DIR_SCRIPTS}/readme.sh" \
            -c "${OPENWRT_PATH}/.config" \
            -o "${tmp_desc_file}" \
            -s "${system_content:-}" \
            -a "${WRT_MINE_SAY:-}" \
            -r 'false'; then
            cat "${tmp_desc_file}"
            rm -f "${tmp_desc_file}"
            return 0
        fi
        rm -f "${tmp_desc_file}"
    fi

    printf '%s\n' "${system_content:-}"
}

write_notify_content() {
    local target_file="$1"
    local notify_body=""

    notify_body="$(get_notify_body)"

    # GitHub Actions 多行变量需要 <<EOF 语法，这里统一封装，避免两处逻辑漂移。
    {
        echo "notify_content<<EOF"
        if [ "${COMPILE_STATUS:-unknown}" = "success" ]; then
            echo "编译状态：✅ 编译成功"
        else
            echo "编译状态：❌ 编译失败"
        fi
        echo ""
        if [ "${COMPILE_STATUS:-unknown}" = "success" ] && [ "${WRT_RELEASE_FIRMWARE:-false}" = "true" ]; then
            echo "Release下载地址：https://github.com/${GITHUB_REPOSITORY}/releases/tag/${release_tag}"
        fi
        if [ "${COMPILE_STATUS:-unknown}" = "success" ]; then
            echo "Artifact下载地址：${artifact_url}"
            echo ""
        fi
        printf '%s\n' "${notify_body}"
        echo ""
        echo "编译结束：${END_TIME:-}"
        echo "EOF"
    } >> "${target_file}"
}

write_notify_content "${GITHUB_ENV}"
write_notify_content "${GITHUB_OUTPUT}"

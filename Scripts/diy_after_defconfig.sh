#!/bin/bash
#=================================================
# Description: DIY script
# Lisence: MIT
# Author: Linjw
# 通用的diy配置脚本
# 该脚本在config确认后于openwrt目录下执行
# 主要职责：根据最终 .config 补充架构相关资源，例如 HomeProxy 规则集。
#=================================================

# 运行在openwrt目录下
current_script_dir=$(cd $(dirname $0) && pwd)
echo "【Lin】脚本目录：${current_script_dir}"
current_dir=$(pwd)
openwrt_workdir="${current_dir}"
target_label_marker_file="./.linjw-target-label"

# 配置
PRELOAD_HOMEPROXY_RESOURCES=false # 是否预置 HomeProxy 规则资源，true/false，默认false

# 获取CPU架构
cputype=$(grep -m 1 "^CONFIG_TARGET_ARCH_PACKAGES=" ./.config | awk -F'=' '{print $2}' | tr -d '"')
cputype_simple=''
# 定义支持的 ARM64 架构处理器型号
arm64_processors=("cortex-a53" "cortex-a57" "cortex-a73" "cortex-a77")
# 判断是否包含这些处理器型号
for processor in "${arm64_processors[@]}"; do
    [[ "$cputype" == *"$processor"* ]] && cputype_simple='arm64' && break
done

if [ -z "${cputype_simple}" ]; then
    # 定义 x86 架构相关的关键词
    x86_keywords=("x86" "amd64")
    # 判断是否包含 x86 架构关键词
    for keyword in "${x86_keywords[@]}"; do
        [[ "$cputype" == *"$keyword"* ]] && cputype_simple='amd64' && break
    done   
fi

echo "【Lin】设备架构：${cputype_simple:-'未知架构'} ${cputype}"

get_config_value() {
    local key="$1"
    grep -m 1 "^${key}=" ./.config | awk -F'=' '{print $2}' | tr -d '"'
}

configure_ecm_accel_delay_fix() {
    local ecm_init_file="./package/qca/qca-nss-ecm/files/qca-nss-ecm.init"
    local ax18_device_config='^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_cmiot_ax18=y$'
    local ax6600_device_config='^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y$'
    local marker_file="${target_label_marker_file:-./.linjw-target-label}"
    local target_label
    local matched_device=""

    [ -f "${ecm_init_file}" ] || return 0
    [ -f "${marker_file}" ] || return 0

    target_label=$(tr -d '\r' < "${marker_file}" | tr '[:upper:]' '[:lower:]')
    case "${target_label}" in
        cmiot-ax18-nowifi|cmiot-ax18-nowifi-fw3|cmiot-ax18-nowifi-fw4)
            matched_device="cmiot-ax18"
            ;;
        jd-ax6600-wifi*)
            matched_device="jd-ax6600"
            ;;
        *)
            return 0
            ;;
    esac

    case "${matched_device}" in
        cmiot-ax18)
            grep -q "${ax18_device_config}" ./.config 2>/dev/null || return 0
            ;;
        jd-ax6600)
            grep -q "${ax6600_device_config}" ./.config 2>/dev/null || return 0
            ;;
    esac

    # qca-nss-ecm 默认把 accel_delay_pkts 设为 1，表示双向流量一出现就很快允许加速。
    # 在 AX18/AX6600 上这会导致微信朋友圈相关连接过早进入 ECM，出现无法刷新的问题。
    # 改为 24 后，连接会先多走少量慢路径包，再进入 ECM；这是当前实机验证可用且
    # 相对保守的最小有效值，比彻底关闭 ECM 或使用极大延迟值的副作用更小。
    sed -i 's#echo 1 > /sys/kernel/debug/ecm/ecm_classifier_default/accel_delay_pkts#echo 24 > /sys/kernel/debug/ecm/ecm_classifier_default/accel_delay_pkts#' "${ecm_init_file}"
    if grep -qF "echo 24 > /sys/kernel/debug/ecm/ecm_classifier_default/accel_delay_pkts" "${ecm_init_file}"; then
        echo "【Lin】已为 ${matched_device} 将 ECM 默认 accel_delay_pkts 调整为 24"
    fi
}

# 预置openclash核心
preload_openclash_meta_core() {
    local choose_type_openclash
    local app_openclash_dir
    local openclash_dir
    local core_dir
    local clash_arch
    local target_label

    # 检查 OpenClash 是否启用
    choose_type_openclash=$(get_config_value "CONFIG_PACKAGE_luci-app-openclash")
    app_openclash_dir=$(find ./package ./feeds/luci ./feeds/packages -maxdepth 3 -type d -iname "luci-app-openclash" -print -quit 2>/dev/null)

    if [ -z "${choose_type_openclash}" ] || [ "${choose_type_openclash}" = "n" ] || [ ! -d "${app_openclash_dir}" ]; then
        echo "【Lin】未启用 luci-app-openclash，跳过内核预置"
        return 0
    fi

    # 检查设备是否为 AX6600 或 GL-MT6000（仅这两款大内存设备预置）
    target_label=$(tr -d '\r' < "${target_label_marker_file}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
    case "${target_label}" in
        jd-ax6600-wifi*|gl-mt6000-wifi*)
            ;;
        *)
            echo "【Lin】设备 ${target_label:-未知} 不在预置列表中，跳过 OpenClash 内核预置"
            return 0
            ;;
    esac

    openclash_dir=$(readlink -f "${app_openclash_dir}")
    [ -d "${openclash_dir}" ] || return 0

    # 创建内核目录
    core_dir="${openclash_dir}/root/etc/openclash/core"
    mkdir -p "${core_dir}"

    # 根据架构选择内核
    case "${cputype_simple}" in
        arm64) clash_arch="arm64" ;;
        amd64) clash_arch="amd64" ;;
        *)
            echo "【Lin】不支持的架构：${cputype_simple}，跳过 OpenClash 内核预置"
            return 0
            ;;
    esac

    # 下载 Clash Meta 内核
    local core_url="https://github.com/vernesong/OpenClash/core/raw/master/meta/clash-linux-${clash_arch}"
    echo "【Lin】下载 OpenClash Meta 内核：${core_url}"
    if curl -sL -o "${core_dir}/clash_meta" "${core_url}"; then
        chmod +x "${core_dir}/clash_meta"
        echo "【Lin】OpenClash Meta 内核预置完成"
    else
        echo "【Lin】警告：OpenClash Meta 内核下载失败"
    fi
}

# 预置hp资源
preload_homeproxy_resources() {
    local choose_type_homeproxy
    local app_homeproxy_dir
    local homeproxy_dir
    local hp_rules
    local hp_patch
    local resource_version
    local staging_dir
    local staged_resources
    local previous_resources
    local failed_resources

    if [ "${PRELOAD_HOMEPROXY_RESOURCES:-false}" != "true" ]; then
        echo "【Lin】HomeProxy 规则资源预置已关闭"
        return 0
    fi

    choose_type_homeproxy=$(get_config_value "CONFIG_PACKAGE_luci-app-homeproxy")
    app_homeproxy_dir=$(find ./package ./feeds/luci ./feeds/packages -maxdepth 3 -type d -iname "luci-app-homeproxy" -print -quit 2>/dev/null)

    if [ -z "${choose_type_homeproxy}" ] || [ "${choose_type_homeproxy}" = "n" ] || [ ! -d "${app_homeproxy_dir}" ]; then
        echo "【Lin】未启用 luci-app-homeproxy，跳过规则资源预置"
        return 0
    fi

    homeproxy_dir=$(readlink -f "${app_homeproxy_dir}")
    [ -d "${homeproxy_dir}" ] || return 0

    hp_rules="${homeproxy_dir}/root/etc/homeproxy/my_surge"
    hp_patch="${homeproxy_dir}/root/etc/homeproxy"

    chmod +x "${hp_patch}"/scripts/* 2>/dev/null || true

    staging_dir=$(mktemp -d "${homeproxy_dir}/.homeproxy-resources.XXXXXX") || {
        echo "【Lin】警告：无法创建 HomeProxy 规则资源暂存目录"
        return 1
    }
    hp_rules="${staging_dir}/surge-rules"
    staged_resources="${staging_dir}/resources"

    if ! git clone -q --depth=1 --single-branch --branch "release" "https://github.com/Loyalsoldier/surge-rules.git" "${hp_rules}"; then
        echo "【Lin】警告：HomeProxy 规则资源下载失败，保留现有资源"
        rm -rf "${staging_dir}"
        return 1
    fi

    resource_version=$(cd "${hp_rules}" && git log -1 --pretty=format:'%s' | grep -o '[0-9][0-9]*' | head -n 1)
    if [ -z "${resource_version}" ] || [ ! -s "${hp_rules}/cncidr.txt" ] || [ ! -s "${hp_rules}/direct.txt" ] || [ ! -s "${hp_rules}/gfw.txt" ]; then
        echo "【Lin】警告：HomeProxy 规则资源不完整，保留现有资源"
        rm -rf "${staging_dir}"
        return 1
    fi

    mkdir -p "${staged_resources}"
    printf '%s\n' "${resource_version}" > "${staged_resources}/china_ip4.ver"
    printf '%s\n' "${resource_version}" > "${staged_resources}/china_ip6.ver"
    printf '%s\n' "${resource_version}" > "${staged_resources}/china_list.ver"
    printf '%s\n' "${resource_version}" > "${staged_resources}/gfw_list.ver"

    if ! awk -F, '$1 == "IP-CIDR" {print $2}' "${hp_rules}/cncidr.txt" > "${staged_resources}/china_ip4.txt" ||
        ! awk -F, '$1 == "IP-CIDR6" {print $2}' "${hp_rules}/cncidr.txt" > "${staged_resources}/china_ip6.txt" ||
        ! sed 's/^\.//g' "${hp_rules}/direct.txt" > "${staged_resources}/china_list.txt" ||
        ! sed 's/^\.//g' "${hp_rules}/gfw.txt" > "${staged_resources}/gfw_list.txt"; then
        echo "【Lin】警告：HomeProxy 规则资源转换失败，保留现有资源"
        rm -rf "${staging_dir}"
        return 1
    fi

    for resource in china_ip4 china_ip6 china_list gfw_list; do
        if [ ! -s "${staged_resources}/${resource}.ver" ] || [ ! -s "${staged_resources}/${resource}.txt" ]; then
            echo "【Lin】警告：HomeProxy 规则资源转换结果为空，保留现有资源"
            rm -rf "${staging_dir}"
            return 1
        fi
    done

    previous_resources="${homeproxy_dir}/.homeproxy-resources.previous.$$"
    rm -rf "${previous_resources}"
    if [ -d "${hp_patch}/resources" ] && ! mv "${hp_patch}/resources" "${previous_resources}"; then
        echo "【Lin】警告：无法备份现有 HomeProxy 规则资源"
        rm -rf "${staging_dir}"
        return 1
    fi

    if ! mv "${staged_resources}" "${hp_patch}/resources"; then
        echo "【Lin】警告：无法安装新的 HomeProxy 规则资源，尝试恢复现有资源"
        failed_resources="${homeproxy_dir}/.homeproxy-resources.failed.$$"
        rm -rf "${failed_resources}"
        if [ -e "${hp_patch}/resources" ]; then
            if ! mv "${hp_patch}/resources" "${failed_resources}"; then
                echo "【Lin】错误：HomeProxy 规则资源恢复失败，原资源备份保留在 ${previous_resources}"
                rm -rf "${staging_dir}"
                return 1
            fi
        fi
        if [ -d "${previous_resources}" ] && ! mv "${previous_resources}" "${hp_patch}/resources"; then
            echo "【Lin】错误：HomeProxy 规则资源恢复失败，原资源备份保留在 ${previous_resources}"
            [ -e "${failed_resources}" ] && mv "${failed_resources}" "${hp_patch}/resources"
            rm -rf "${staging_dir}"
            return 1
        fi
        if [ -e "${failed_resources}" ]; then
            echo "【Lin】警告：安装冲突的 HomeProxy 规则资源保留在 ${failed_resources}"
        fi
        rm -rf "${staging_dir}"
        return 1
    fi

    rm -rf "${previous_resources}" "${staging_dir}"

    echo "【Lin】homeproxy data has been updated!"
}

cd "${openwrt_workdir}"

# preload_openclash_meta_core
preload_homeproxy_resources

source_type_helper="${current_script_dir}/lib/source_type.sh"
[ -f "${source_type_helper}" ] && . "${source_type_helper}"
SOURCE_TYPE=$(resolve_source_type "${SOURCE_TYPE:-auto}" "${openwrt_workdir}")

if [ "${SOURCE_TYPE}" = "lean" ]; then
    configure_ecm_accel_delay_fix
fi


#写入自定义APK软件源及签名公钥
mkdir -p ./files/etc/apk/keys ./files/etc/apk/repositories.d

cat > ./files/etc/apk/repositories.d/substore.list <<EOF
https://substore-openwrt.pages.dev/openwrt-25.12/all/packages.adb
EOF

cat > ./files/etc/apk/keys/substore-apk.pem <<'EOF'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEJKvnnTePdD16sK/rksork3HzOxeQ
YJjfM7/Fd1eVSpC7k4I/80OpF8lxuoCMbNilssnMtG2WUv/idDjcIEa+Lw==
-----END PUBLIC KEY-----
EOF

#!/bin/bash

# 说明：
# 1. 该脚本在 OpenWrt 的 package 目录下执行，用于删除、替换和修补第三方插件包。
# 2. 入口职责保持不变：先应用通用包清单和 lean 专属覆盖，再执行一组编译兼容性修补。
# 3. 结构上拆成三层：通用包操作函数、lean 专属包清单、后置修补函数。
# 4. 这个脚本不负责 menuconfig 选包，只负责把 package/ 与部分 feeds 中的包替换成指定来源版本。
# 5. 包合集先下载并确认目标目录，再替换同名包，避免失败时误删现有包。

current_script_dir=$(cd "$(dirname "$0")" && pwd)
echo "【Lin】脚本目录：${current_script_dir}"

luci_feed_helper="${current_script_dir}/lib/luci_feed_compat.sh"
[ -f "${luci_feed_helper}" ] && . "${luci_feed_helper}"
source_type_helper="${current_script_dir}/lib/source_type.sh"
[ -f "${source_type_helper}" ] && . "${source_type_helper}"

# 允许从仓库根目录执行，脚本会自行切换到 package/；
# 如果当前目录和子目录里都没有 package/，则直接退出，避免误删其它路径。
if [ "$(basename "$(pwd)")" != 'package' ]; then
    if [ -d "./package" ]; then
        cd ./package
    else
        echo "【Lin】请在package目录下执行，当前工作目录：$(pwd)"
        exit 0
    fi
fi

package_workdir=$(pwd)
openwrt_workdir="$(readlink -f ..)"
luci_feed_branch='unknown'

# 源码类型：根据 lean 特有文件自动判断；非 lean 统一按 iwrt 配置族处理。
SOURCE_TYPE=$(resolve_source_type "${SOURCE_TYPE:-auto}" "$openwrt_workdir")
SOURCE_CONFIG_FAMILY=$(source_config_family "${SOURCE_TYPE}")
echo "【Lin】源码类型：${SOURCE_TYPE}"
echo "【Lin】配置族：${SOURCE_CONFIG_FAMILY}"

echo "【Lin】工作目录：${package_workdir}"

# 在 package/、feeds/luci/、feeds/packages/ 三个常见来源中查找同名包。
# 这样无论包来自官方 feeds 还是第三方仓库，都能先做统一清理。
find_package_dirs() {
    local package_name=$1

    find ./ ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d \
        \( -name 'pkglist_*' -prune \) -o \
        \( -type d -iname "$package_name" -print \) 2>/dev/null
}

# 统一把 owner/repo 形式转换成完整 GitHub URL；
# 已经是完整 URL（以 http/https 开头）时保持不变，兼容脚本中多种写法。
normalize_repo_url() {
    local package_repo=$1

    if [[ "${package_repo}" == http://* ]] || [[ "${package_repo}" == https://* ]]; then
        printf '%s\n' "${package_repo}"
    elif [[ "${package_repo}" == *github.com* ]]; then
        printf '%s\n' "${package_repo}"
    else
        printf 'https://github.com/%s.git\n' "${package_repo}"
    fi
}

# 分支或 tag 使用浅克隆；完整 commit SHA 则用兼容的 fetch 流程检出。
clone_repo_shallow() {
    local repo_url=$1
    local repo_ref=$2
    local repo_name=$3
    local ls_remote_status

    if [[ "${repo_ref}" =~ ^[0-9a-fA-F]{40}$ ]]; then
        # 40 位十六进制分支或 tag 虽少见但合法，优先按远端 ref 处理以保持旧行为。
        if git ls-remote --exit-code --heads --tags "${repo_url}" "${repo_ref}" >/dev/null 2>&1; then
            git clone --depth=1 --single-branch --branch "${repo_ref}" "${repo_url}" "${repo_name}"
            return
        else
            ls_remote_status=$?
        fi

        if [ "${ls_remote_status}" -ne 2 ]; then
            echo "【Lin】无法确认远端引用：${repo_ref}" >&2
            return "${ls_remote_status}"
        fi

        git init -q "${repo_name}" || return
        git -C "${repo_name}" remote add origin "${repo_url}" || return
        git -C "${repo_name}" fetch --depth=1 origin "${repo_ref}" || return
        git -C "${repo_name}" checkout --detach FETCH_HEAD || return
        return
    fi

    git clone --depth=1 --single-branch --branch "${repo_ref}" "${repo_url}" "${repo_name}"
}

# 删除同名包是所有替换动作的第一步。
# 这里按包名删除，而不是按仓库名删除，目的是清掉官方 feeds 与旧第三方来源中的同名目录。
DELETE_PACKAGE() {
    local package_name=$1
    local found_dirs

    found_dirs=$(find_package_dirs "${package_name}")
    if [ -n "${found_dirs}" ]; then
        while read -r dir; do
            rm -rf "${dir}"
            echo "【Lin】删除文件夹：${dir}"
        done <<< "${found_dirs}"
    else
        echo "【Lin】未找到文件夹：${package_name}"
    fi
}

# UPDATE_PACKAGE 适用于“一仓库对应一个包目录”的场景。
# package_special:
# - 空：直接保留仓库原目录名
# - pkg：从大杂烩仓库里抽取指定子目录
# - name：把仓库目录重命名成 package_name
UPDATE_PACKAGE() {
    local package_name=$1
    local package_repo=$2
    local package_ref=$3
    local package_special=${4:-}
    local search_type=$package_name
    local full_repo
    local repo_url_git
    local repo_name
    local search_result_pkg_dir

    DELETE_PACKAGE "${package_name}"

    full_repo=$(normalize_repo_url "${package_repo}")
    repo_url_git=${full_repo%.git}
    repo_name=${repo_url_git##*/}

    clone_repo_shallow "${full_repo}" "${package_ref}" "${repo_name}"
    echo "【Lin】成功clone插件：${package_name} [库：${repo_name} | 引用：${package_ref}]"

    case "${package_special}" in
        pkg)
            # 一些仓库根目录只是包集合，真正要编译的是里面某个子目录。
            # 这里先保留整个仓库，再把目标子目录复制到 package/ 根下。
            search_result_pkg_dir=$(find "./${repo_name}"/*/ -maxdepth 1 -type d -iname "${search_type}" -prune)
            if [ -n "${search_result_pkg_dir}" ]; then
                mv -f "${repo_name}" "${repo_name}_bak"
                cp -rf $(find "./${repo_name}_bak"/*/ -maxdepth 1 -type d -iname "${search_type}" -prune) "./${search_type}"
                rm -rf "./${repo_name}_bak/"
            fi
            ;;
        name)
            # 对仓库名和包名不一致的情况，直接把 clone 下来的目录改成目标包名。
            mv -f "${repo_name}" "${package_name}"
            echo "【Lin】重命名插件：${package_name} <= ${repo_name}"
            ;;
    esac
}

# 用于从“包合集仓库”中逐个拷出需要的目录。
# 这里不移动而是复制，是为了允许一个仓库中提取多个包，最后再统一删除临时仓库目录。
MOVE_PACKAGE_FROM_LIST() {
    local package_name=$1
    local list_repo=$2
    local found

    found=$(find "./${list_repo}" -mindepth 1 -maxdepth 2 -type d -iname "${package_name}" -print | head -n 1)
    if [ -n "${found}" ]; then
        DELETE_PACKAGE "${package_name}"
        cp -rf "${found}" ./ || return
        echo "【Lin】复制插件包库${list_repo}的${package_name}到package中"
    else
        echo "【Lin】未找到插件包库${list_repo}的${package_name}"
    fi
}

# update_package_list 适用于“一个仓库内维护多个包目录”的场景。
# package_name_list 是空格分隔列表，函数会：
# 1. 临时克隆包合集仓库，失败时保留现有包
# 2. 确认目标目录存在后才删除对应旧包
# 3. 按列表逐个复制目标目录到 package/
# 4. 删除临时仓库，避免 package/ 中残留整个合集
update_package_list() {
    local package_name_list=($1)
    local package_repo=$2
    local package_ref=$3
    local repo_root_files=${4:-}
    local full_repo
    local repo_url_git
    local repo_name_last
    local repo_name
    local existing_repo
    local package_name repo_root_file clone_status

    full_repo=$(normalize_repo_url "${package_repo}")
    repo_url_git=${full_repo%.git}
    repo_name_last=${repo_url_git##*/}
    # 临时仓库目录名转成 pkglist_owner_repo 形式，避免和真实包目录重名。
    repo_name=${full_repo#*//}
    repo_name=${repo_name#*/}
    repo_name=${repo_name%.git}
    repo_name=${repo_name//\//_}
    repo_name="pkglist_${repo_name:-$repo_name_last}"

    existing_repo=$(find ./ ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "${repo_name}" -prune)
    if [ -n "${existing_repo}" ]; then
        echo "【Lin】删除同名插件包库：${existing_repo}"
        rm -rf "${existing_repo}"
    fi

    echo "【Lin】下载插件库${repo_name}：【${package_ref}】${full_repo}"
    if clone_repo_shallow "${full_repo}" "${package_ref}" "${repo_name}"; then
        :
    else
        clone_status=$?
        rm -rf "${repo_name}"
        echo "【Lin】下载插件包库失败：${full_repo}，保留现有包" >&2
        return "${clone_status}"
    fi
    echo "【Lin】成功clone插件包库：${repo_name}"

    for package_name in "${package_name_list[@]}"; do
        MOVE_PACKAGE_FROM_LIST "${package_name}" "${repo_name}" || {
            rm -rf "${repo_name}"
            return 1
        }
    done

    if [ -n "${repo_root_files}" ]; then
        for repo_root_file in ${repo_root_files}; do
            if [ -f "./${repo_name}/${repo_root_file}" ]; then
                cp -f "./${repo_name}/${repo_root_file}" "./${repo_root_file}"
                echo "【Lin】复制插件包库${repo_name}的根文件${repo_root_file}到package中"
            else
                echo "【Lin】未找到插件包库${repo_name}的根文件：${repo_root_file}"
            fi
        done
    fi

    echo "【Lin】删除插件包库：${repo_name}"
    rm -rf "${repo_name}"
}

# luci-app-lanspeed 仓库同时维护 LuCI 前端与后端守护进程，
# 这里按上游目录结构分别拷出 applications/ 与 net/ 下的两个目标包。
UPDATE_LANSPEED() {
    local LANSPEED_REPO="https://github.com/qimaoww/luci-app-lanspeed.git"
    local TMP_DIR

    TMP_DIR=$(mktemp -d) || {
        echo "【Lin】无法创建 luci-app-lanspeed 临时目录" >&2
        return 1
    }

    DELETE_PACKAGE "luci-app-lanspeed"
    DELETE_PACKAGE "lanspeedd"
    rm -rf "${package_workdir}/luci-app-lanspeed" "${package_workdir}/lanspeedd"

    if ! git clone --depth 1 --single-branch "${LANSPEED_REPO}" "${TMP_DIR}"; then
        rm -rf "${TMP_DIR}"
        return 1
    fi

    if [ ! -f "${TMP_DIR}/applications/luci-app-lanspeed/Makefile" ]; then
        echo "【Lin】luci-app-lanspeed Makefile not found in ${LANSPEED_REPO}" >&2
        rm -rf "${TMP_DIR}"
        return 1
    fi

    if [ ! -f "${TMP_DIR}/net/lanspeedd/Makefile" ]; then
        echo "【Lin】lanspeedd Makefile not found in ${LANSPEED_REPO}" >&2
        rm -rf "${TMP_DIR}"
        return 1
    fi

    cp -rf "${TMP_DIR}/applications/luci-app-lanspeed" "${package_workdir}/luci-app-lanspeed"
    cp -rf "${TMP_DIR}/net/lanspeedd" "${package_workdir}/lanspeedd"
    rm -rf "${TMP_DIR}"
    echo "【Lin】成功导入 luci-app-lanspeed / lanspeedd"
}

# 备用方案：当单独维护的 luci-app-ninjaconnector2 包仓库不可用时，
# 可临时改回这个函数，从上游 release ipk 解包生成本地 OpenWrt 包。
prepare_ninjaconnector2_package() {
    local package_name="luci-app-ninjaconnector2"
    local package_version="1.1.0"
    local package_release="4"
    local package_file="${package_name}_${package_version}-${package_release}_all.ipk"
    local package_url="https://github.com/kachetong1314/ninja/releases/download/0.1.13/${package_file}"
    local package_sha256="067872b03de0f5fc214fc1c5ea840502a93faa8b1f44454230661b3d677eb315"
    local tmp_dir

    tmp_dir=$(mktemp -d) || {
        echo "【Lin】无法创建 ${package_name} 临时目录" >&2
        return 1
    }

    DELETE_PACKAGE "${package_name}"
    mkdir -p "${package_name}/files"

    # 只把上游 ipk 当作 LuCI 文件载体；最终仍由当前源码树按 ipk/apk 模式重新打包。
    if ! curl -L -o "${tmp_dir}/${package_file}" "${package_url}"; then
        rm -rf "${tmp_dir}"
        return 1
    fi

    if ! printf '%s  %s\n' "${package_sha256}" "${tmp_dir}/${package_file}" | sha256sum -c -; then
        rm -rf "${tmp_dir}" "${package_name}"
        return 1
    fi

    if ! gzip -dc "${tmp_dir}/${package_file}" | tar -xf - -C "${tmp_dir}" ./data.tar.gz; then
        rm -rf "${tmp_dir}" "${package_name}"
        return 1
    fi

    if ! tar -xzf "${tmp_dir}/data.tar.gz" -C "${package_name}/files"; then
        rm -rf "${tmp_dir}" "${package_name}"
        return 1
    fi

    chmod +x "${package_name}"/files/usr/share/ninjaconnector2/*.sh "${package_name}"/files/etc/uci-defaults/* 2>/dev/null || true

    cat > "${package_name}/Makefile" <<EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=${package_name}
PKG_VERSION:=${package_version}
PKG_RELEASE:=${package_release}
PKG_MAINTAINER:=Ninja
PKGARCH:=all

include \$(INCLUDE_DIR)/package.mk

define Package/${package_name}
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Ninja core and subscription support for OpenClash
  DEPENDS:=+luci-base +luci-compat +luci-app-openclash +curl +ca-bundle +jsonfilter
endef

define Build/Compile
endef

define Package/${package_name}/install
	\$(CP) ./files/* \$(1)/
endef

\$(eval \$(call BuildPackage,${package_name}))
EOF

    rm -rf "${tmp_dir}"
    echo "【Lin】成功导入 ${package_name} ${package_version}-${package_release}"
}

pin_easytier_binary_version() {
    local package_dir=$1
    local target_version=${2:-}
    local makefiles="
${package_dir}/easytier/Makefile
${package_dir}/easytier-noweb/Makefile
"
    local makefile
    local temp_file

    if [ -z "${target_version}" ]; then
        echo "【Lin】未指定 EasyTier 后端版本，保持上游默认版本"
        return 0
    fi

    for makefile in ${makefiles}; do
        if [ ! -f "${makefile}" ]; then
            echo "【Lin】未找到 EasyTier Makefile：${makefile}"
            continue
        fi

        temp_file=$(mktemp "${makefile##*/}.XXXXXX") || {
            echo "【Lin】警告：无法创建 EasyTier Makefile 临时文件：${makefile}"
            return 0
        }

        awk '
            {
                if ($0 ~ /^PKG_VERSION:=/) {
                    print "PKG_VERSION:=" version
                    next
                }
                print
            }
        ' version="${target_version}" "${makefile}" > "${temp_file}"

        mv -f "${temp_file}" "${makefile}"
    done

    echo "【Lin】已固定 EasyTier 后端版本：${target_version}"
}

# safe_update_package 适用于“要直接覆盖现有包目录，但失败时必须可回滚”的场景。
# 它比 UPDATE_PACKAGE 更保守：先备份旧目录，再替换，clone 失败则回滚。
safe_update_package() {
    local package_name=$1
    local package_repo=$2
    local package_branch=$3
    local path_default
    local path_default_bak

    path_default=$(find ./ ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "${package_name}" -prune)
    path_default_bak="${path_default}_bak"
    [ -d "${path_default_bak}" ] && rm -rf "${path_default_bak}"

    [ -d "${path_default}" ] && mv -f "${path_default}" "${path_default_bak}" && \
        echo "【Lin】备份${package_name}：${path_default} -> ${path_default_bak}"

    git clone --depth=1 --single-branch -b "${package_branch}" "${package_repo}" "${path_default}"
    if [ -d "${path_default}" ]; then
        echo "【Lin】替换${package_name}成功：${path_default}"
        [ -d "${path_default_bak}" ] && rm -rf "${path_default_bak}"
    else
        mv -f "${path_default_bak}" "${path_default}"
        echo "【Lin】替换${package_name}失败，还原${package_name}"
    fi
}

# UPDATE_VERSION 只处理采用 GitHub release/tarball 模式且 Makefile 可自动推导版本号的包。
# 它不会下载源码树，只会改 Makefile 里的 PKG_VERSION 与 PKG_HASH。
UPDATE_VERSION() {
    local package_name=$1
    local package_mark=${2:-false}
    local package_files
    local package_file

    package_files=$(find ./ ../feeds/packages/ -maxdepth 3 -type f -wholename "*/${package_name}/Makefile")
    echo " "

    if [ -z "${package_files}" ]; then
        echo "${package_name} not found!"
        return
    fi

    echo -e "\n${package_name} version update has started!"

    for package_file in ${package_files}; do
        local package_repo
        local package_tag
        local old_ver
        local old_url
        local old_file
        local old_hash
        local package_url
        local new_ver
        local new_url
        local new_hash

        package_repo=$(grep -Po "PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)" "${package_file}")
        package_tag=$(curl -sL "https://api.github.com/repos/${package_repo}/releases" | jq -r "map(select(.prerelease == ${package_mark})) | first | .tag_name")

        old_ver=$(grep -Po "PKG_VERSION:=\K.*" "${package_file}")
        old_url=$(grep -Po "PKG_SOURCE_URL:=\K.*" "${package_file}")
        old_file=$(grep -Po "PKG_SOURCE:=\K.*" "${package_file}")
        old_hash=$(grep -Po "PKG_HASH:=\K.*" "${package_file}")

        package_url=$([[ ${old_url} == *"releases"* ]] && echo "${old_url%/}/${old_file}" || echo "${old_url%/}")
        new_ver=$(echo "${package_tag}" | sed -E 's/[^0-9]+/\./g; s/^\.|\.$//g')
        new_url=$(echo "${package_url}" | sed "s/\$(PKG_VERSION)/${new_ver}/g; s/\$(PKG_NAME)/${package_name}/g")
        new_hash=$(curl -sL "${new_url}" | sha256sum | cut -d ' ' -f 1)

        echo "old version: ${old_ver} ${old_hash}"
        echo "new version: ${new_ver} ${new_hash}"

        if [[ ${new_ver} =~ ^[0-9].* ]] && dpkg --compare-versions "${old_ver}" lt "${new_ver}"; then
            sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=${new_ver}/g" "${package_file}"
            sed -i "s/PKG_HASH:=.*/PKG_HASH:=${new_hash}/g" "${package_file}"
            echo "【Lin】${package_file} version has been updated!"
        else
            echo "【Lin】${package_file} version is already the latest!"
        fi
    done
}

# 解析 LuCI feed 分支类型，用于后续差异化处理。
# 从 feeds.conf.default 中提取 src-git luci 行的分支标识，
# 并通过 canonicalize_luci_feed_branch_token 归一化为标准格式（如 openwrt-24.10）。
# 结果存入全局变量 luci_feed_branch，供后续 apply_*_package_overrides 判断使用。
resolve_packages_luci_feed_branch() {
    if command -v resolve_luci_feed_branch >/dev/null 2>&1; then
        luci_feed_branch=$(resolve_luci_feed_branch "${openwrt_workdir}/feeds.conf.default")
    else
        luci_feed_branch='unknown'
    fi

    echo "【Lin】LuCI feed 分支：${luci_feed_branch}"
}

# 通用包清单：所有构建都会执行。
# 这里应该只放“对当前 lean 源码树始终通用”的替换，不要放只在特定场景才成立的覆盖。
apply_common_package_overrides() {
    # UPDATE_PACKAGE "luci-theme-kucat" "sirpdboy/luci-theme-kucat" "master"
    UPDATE_PACKAGE "luci-theme-noobwrt" "nooblk-98/luci-theme-noobwrt" "master"
    UPDATE_PACKAGE "luci-theme-fluent" "LazuliKao/luci-theme-fluent" "main"
    UPDATE_PACKAGE "aurora" "eamonxg/luci-theme-aurora" "master"
    UPDATE_PACKAGE "aurora-config" "eamonxg/luci-app-aurora-config" "master"
    
    # UPDATE_PACKAGE "luci-app-openclash" "vernesong/OpenClash" "v0.47.116" "pkg"
    UPDATE_PACKAGE "luci-app-openclash" "vernesong/OpenClash" "master" "pkg"
    UPDATE_PACKAGE "luci-app-ninjaconnector2" "jw10126121/luci-app-ninjaconnector2" "main"
    # prepare_ninjaconnector2_package

    # 订阅转换
    update_package_list "luci-app-miaomiaowu miaomiaowu" "XiaoHaiSly/luci-app-miaomiaowu" "main"
    # UPDATE_PACKAGE "luci-app-miaomiaowu" "xiaohai77/OpenWrt-mmw" "main" "pkg"
    UPDATE_PACKAGE "luci-app-subconverter" "0x2196f3/luci-app-subconverter" "main" "pkg" # 目前2026/07/03只支持aarch64
    fix_luci_app_subconverter_postinst
    # UPDATE_PACKAGE "luci-app-substore" "xiaohai77/luci-app-substore" "main" "pkg"
    # update_package_list "luci-app-subconverter" "0x2196f3/luci-app-subconverter" "main"

    update_package_list "luci-app-onliner" "danchexiaoyang/luci-app-onliner" "main"
    update_package_list "wrtbwmon" "brvphoenix/wrtbwmon" "master"
    update_package_list "luci-app-wrtbwmon" "brvphoenix/luci-app-wrtbwmon" "master"
    # UPDATE_LANSPEED
    update_package_list "luci-app-lanspeed lanspeedd" "qimaoww/luci-app-lanspeed" "master"
    update_package_list "luci-app-oaf oaf open-app-filter" "destan19/OpenAppFilter" "master"

    safe_update_package "frp" "https://github.com/jw10126121/openwrt_frp" "main" # "v0.69.0"
    update_package_list "luci-app-frpc luci-app-frps" "superzjg/luci-app-frpc_frps" "main"
    ensure_luci_app_frp_init_permissions
    
    # UPDATE_PACKAGE "luci-app-wechatpush" "peiban666/luci-app-wechatpush" "master"
    UPDATE_PACKAGE "luci-app-wechatpush" "tty228/luci-app-wechatpush" "master"
    fix_wechatpush_runtime
    UPDATE_PACKAGE "luci-app-pushbot" "zzsj0928/luci-app-pushbot" "master"
    fix_pushbot_runtime

    # update_package_list "luci-app-easytier easytier easytier-noweb" "EasyTier/luci-app-easytier" "main"
    update_package_list "luci-app-easytier easytier easytier-noweb" "EasyTier/luci-app-easytier" "v2.6.4"
    #local easytier_release_version='2.4.5' # 注释掉这两行表示跟随包仓声明版本
    #pin_easytier_binary_version "." "${easytier_release_version}"
    

    UPDATE_PACKAGE "luci-app-bandix" "timsaya/luci-app-bandix" "main"
    UPDATE_PACKAGE "openwrt-bandix" "timsaya/openwrt-bandix" "main"

    # 保留可选 Socat 页面，依赖会自动带出 socat
    update_package_list "luci-app-socat luci-app-guest-wifi" "Lienol/openwrt-package" "main"    
    update_package_list "luci-app-clientstatus clientstatus" "migee99/luci-app-clientstatus" "main"    

    # UPDATE_PACKAGE "luci-app-athena-led" "NONGFAH/luci-app-athena-led" "main"
    # # NONGFAH 版本的 init 脚本和主程序需要可执行权限，否则安装后服务无法启动
    # [ -f ./luci-app-athena-led/root/etc/init.d/athena_led ] && chmod +x ./luci-app-athena-led/root/etc/init.d/athena_led && echo "【Lin】修复权限：luci-app-athena-led/root/etc/init.d/athena_led"
    # [ -f ./luci-app-athena-led/root/usr/sbin/athena-led ] && chmod +x ./luci-app-athena-led/root/usr/sbin/athena-led && echo "【Lin】修复权限：luci-app-athena-led/root/usr/sbin/athena-led"
    # LuCI2-JS 的前端依赖同仓库的 Rust 后端，需要一起导入。
    update_package_list "luci-app-athena-led athena-led" "Sh1rokoDev/luci-app-athena-led" "LuCI2-JS"
    fix_athena_led_makefile

    # Guest-WIFI
    # UPDATE_PACKAGE "luci-app-guest-wifi" "kenzok78/luci-app-guest-wifi" "main" # 不可用
    # 3频可用，但20260604编译报错
    # update_package_list "luci-app-guestwifi" "yufanpin/luci-app-guestwifi" "master"

    # 使用sbwml/luci-app-sqm，这个配合sqm-scripts会报错
    # UPDATE_PACKAGE "luci-app-sqm" "https://git.cooluc.com/sbwml/luci-app-sqm" "main"
    # 以下为sqm备用，未测试
    # UPDATE_PACKAGE "luci-app-sqm" "gitbruc/luci-app-sqm" "main"
    # update_package_list "luci-app-sqm-controller" "Natduki/luci-app-sqm-controller" "main"

    # 只支持ipq807x，不支持ipq60xx
    # update_package_list "sqm-scripts-nss" "JuliusBairaktaris/sqm-scripts-nss" "master"

    # quickfile 当前按需保留，默认不导入。
    # 如果后续重新启用，需要同时确认设备侧是否改成 luci-nginx 路线。
    # update_package_list "luci-app-quickfile quickfile" "sbwml/luci-app-quickfile" "main"

    # luci-app-easymesh未测试 @linjw 20260618
    # lean源码树中 luci-app-adguardhome 版本较旧且缺中文，这里直接从 kenzok8/openwrt-packages 下载
    update_package_list "luci-app-adguardhome adguardhome luci-app-easymesh" "kenzok8/openwrt-packages" "master"

    update_package_list "luci-app-wolplus" "sundaqiang/openwrt-packages" "master"
    
}

# lean 风味额外覆盖。
# 只放 lean 源码树中确实需要替换、且不会和其它风味共享的包。
apply_lean_package_overrides() {
    echo "【Lin】启用lean专属包覆盖"

    # luci-app-vlmcsd：LEDE专用，IMM用自带的
    update_package_list "luci-app-vlmcsd vlmcsd" "sbwml/openwrt_pkgs" "main"

    # 25.12没有的包，从23.05获取
    apply_luci_feed_25_12_package_overrides
    if is_luci_feed_25_12 "${openwrt_workdir}/feeds.conf.default"; then
        # update_package_list "luci-theme-argon luci-app-argon-config" "sbwml/luci-theme-argon" "openwrt-25.12"
        # 使用lean源码自带的argon
        update_package_list "luci-app-argon-config" "sbwml/luci-theme-argon" "openwrt-25.12"
    else
        UPDATE_PACKAGE "luci-theme-argon" "jerrykuku/luci-theme-argon" "v2.3.2"
        UPDATE_PACKAGE "luci-app-argon-config" "jerrykuku/luci-app-argon-config" "master"
    fi

    if ! is_luci_feed_25_12 "${openwrt_workdir}/feeds.conf.default"; then
        update_package_list "luci-app-3cat" "coolsnowwolf/luci" "openwrt-25.12" # 非 25.12 feed 时补入 lean 上游 3cat
    fi
    
    # update_package_list "luci-app-wolplus" "sundaqiang/openwrt-packages" "master"
    update_package_list "luci-app-netspeedtest speedtest-cli" "sbwml/openwrt_pkgs" "main"

    update_package_list "luci-app-verysync verysync" "coolsnowwolf/luci" "openwrt-23.05"

}

# iwrt 配置族源码风格：vwrt/libwrt 共用。
apply_iwrt_package_overrides() {
    echo "【Lin】启用 iwrt 配置族专属包覆盖"
    # UPDATE_PACKAGE "luci-theme-noobwrt" "nooblk-98/luci-theme-noobwrt" "master"
    UPDATE_PACKAGE "shadcn" "eamonxg/luci-theme-shadcn" "main"
    UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "master"
    UPDATE_PACKAGE "kucat-config" "sirpdboy/luci-app-kucat-config" "master"

    UPDATE_PACKAGE "momo" "nikkinikki-org/OpenWrt-momo" "main"
    UPDATE_PACKAGE "nikki" "nikkinikki-org/OpenWrt-nikki" "main"
    # UPDATE_PACKAGE "openclash" "vernesong/OpenClash" "dev" "pkg"
    UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
    UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"

    UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"

    UPDATE_PACKAGE "luci-app-ddns-go" "sirpdboy/luci-app-ddns-go" "main"
    UPDATE_PACKAGE "luci-app-diskman" "sbwml/luci-app-diskman" "main"
    UPDATE_PACKAGE "luci-app-diskmanager" "4IceG/luci-app-mini-diskmanager" "main"
    UPDATE_PACKAGE "luci-app-mosdns" "sbwml/luci-app-mosdns" "v5" "" "v2dat"
    UPDATE_PACKAGE "netspeedtest" "sirpdboy/netspeedtest" "main" "" "homebox ookla-speedtest"
    UPDATE_PACKAGE "netwizard" "sirpdboy/luci-app-netwizard" "main"
    UPDATE_PACKAGE "openlist2" "sbwml/luci-app-openlist2" "main"
    # UPDATE_PACKAGE "partexp" "sirpdboy/luci-app-partexp" "main"
    UPDATE_PACKAGE "qbittorrent" "sbwml/luci-app-qbittorrent" "master" "" "qt6base qt6tools rblibtorrent"
    UPDATE_PACKAGE "qmodem" "FUjr/QModem" "main"
    UPDATE_PACKAGE "luci-app-quickfile" "sbwml/luci-app-quickfile" "main"
    UPDATE_PACKAGE "timecontrol" "sirpdboy/luci-app-timecontrol" "main"
    UPDATE_PACKAGE "viking" "VIKINGYFY/packages" "main" "" "gecoosac luci-app-timewol luci-app-wolplus"
    # UPDATE_PACKAGE "vnt" "lmq8267/luci-app-vnt" "main"

    update_package_list "luci-app-verysync verysync" "immortalwrt/luci" "openwrt-23.05"
    # update_package_list "luci-app-quickstart quickstart" "sbwml/package_new_istore" "main"
    # update_package_list "luci-app-homeproxy sing-box" "VIKINGYFY/packages" "main"
    # UPDATE_VERSION "sing-box" # 升级sing-box到最新release版本，如果使用VIKINGYFY/packages/luci-app-homeproxy，要求sing-box版本>=1.14.0，否则luci-app-homeproxy无法编译成功
    
    # XiaoHaiSly/OpenWRT-packages 已不可访问；保留现有 Node 与通用 AdGuardHome 包。
    update_package_list "luci-app-substore" "XiaoHaiSly/luci-app-substore" "main"

    # 在通用模块中已经导入了 luci-app-adguardhome，所以不再重复导入
    # update_package_list "luci-app-adguardhome adguardhome" "kenzok8/openwrt-packages" "master"

    update_package_list "luci-app-homeproxy sing-box" "XiaoHaiSly/luci-app-homeproxy" "main"
}

# OpenWrt 25.12 的 LuCI 菜单机制与语言包状态和旧分支不同，这里统一补一层兼容：
# 1. vlmcsd / 3cat 使用带 menu.d 与 ACL 的包源，避免控制器在新 LuCI 下不显示。
# 2. accesscontrol / adguardhome 暂时从 coolsnowwolf/luci 的 openwrt-23.05 分支补回。
apply_luci_feed_25_12_package_overrides() {
    if ! is_luci_feed_25_12 "${openwrt_workdir}/feeds.conf.default"; then
        return 0
    fi

    echo "【Lin】检测到 LuCI feed 为 openwrt-25.12，补齐 25.12 兼容包源"

    echo "【Lin】25.12未找到luci-app-accesscontrol和luci-app-filetransfer，从coolsnowwolf/luci的openwrt-23.05分支获取"
    update_package_list "luci-app-accesscontrol luci-app-filetransfer" "coolsnowwolf/luci" "openwrt-23.05" # 25.12 feed 时补入 lean 上游 v23.05 luci-app-accesscontrol和luci-app-filetransfer

}

# quickfile 的上游二进制文件名和本地 OpenWrt 架构名并不总是一一对应。
# 这个修补只在 quickfile 已经被导入时生效；当前默认未启用，所以通常会静默跳过。
fix_quickfile_makefile() {
    local quickfile_makefile

    quickfile_makefile=$(find ./ -maxdepth 3 -type f -wholename "*/quickfile/Makefile")
    if [ -f "${quickfile_makefile}" ]; then
        sed -i '/\t\$(INSTALL_BIN) \$(PKG_BUILD_DIR)\/quickfile-\$(ARCH_PACKAGES)/c\
\tif [ "\$(ARCH_PACKAGES)" = "x86_64" ]; then \\\
\t\t\$(INSTALL_BIN) \$(PKG_BUILD_DIR)\/quickfile-x86_64 \$(1)\/usr\/bin\/quickfile; \\\
\telse \\\
\t\t\$(INSTALL_BIN) \$(PKG_BUILD_DIR)\/quickfile-aarch64_generic \$(1)\/usr\/bin\/quickfile; \\\
\tfi' "${quickfile_makefile}"
        echo "【Lin】修复quickfile问题：${quickfile_makefile}"
    fi
}

# 统一调用外部 helper 处理 node 预编译包兼容问题，避免主脚本继续膨胀。
apply_lang_node_prebuilt_fix() {
    echo "【Lin】尝试使用 sbwml/feeds_packages_lang_node 加速 lang_node 编译"
    if LANG_NODE_PREBUILT_REPO="https://github.com/sbwml/feeds_packages_lang_node" \
        bash "${current_script_dir}/lib/lang_node_prebuilt.sh" "${openwrt_workdir}"; then
        return 0
    fi

    echo "【Lin】未命中可用的 sbwml lang_node 预编译分支，继续使用官方 lang/node"
    return 0
}

# 下列函数都属于“后置修补链”：
# 前提是包已经通过前面的覆盖流程存在于 package/ 或 feeds 中，
# 然后再对 Makefile、脚本、资源文件做最小修补，使其更适配当前源码与设备配置。
ensure_luci_app_frp_init_permissions() {
    local init_file

    for init_file in \
        "./luci-app-frpc/root/etc/init.d/frpc" \
        "./luci-app-frps/root/etc/init.d/frps"; do
        if [ -f "${init_file}" ]; then
            chmod 0755 "${init_file}"
            echo "【Lin】已补齐执行权限：${init_file}"
        fi
    done
}

# LuCI 的单服务重载会直接执行 /etc/init.d/ddns；补齐对应 rpcd ACL。
ensure_luci_app_ddns_acl() {
    local acl_file

    [ "${SOURCE_CONFIG_FAMILY:-}" = "iwrt" ] || return 0

    for acl_file in \
        "./luci-app-ddns/root/usr/share/rpcd/acl.d/luci-app-ddns.json" \
        "../feeds/luci/applications/luci-app-ddns/root/usr/share/rpcd/acl.d/luci-app-ddns.json"; do
        [ -f "${acl_file}" ] || continue

        if grep -Fq '"/etc/init.d/ddns": [ "exec" ]' "${acl_file}"; then
            continue
        fi

        if ! grep -Fq '"file": {' "${acl_file}"; then
            echo "【Lin】跳过 DDNS ACL 修补，未找到 file 权限块：${acl_file}"
            continue
        fi

        perl -0pi -e 's|("file": \{\n)|$1                "/etc/init.d/ddns": [ "exec" ],\n|' "${acl_file}"
        echo "【Lin】已补齐 LuCI DDNS 重载权限：${acl_file}"
    done
}

fix_luci_app_subconverter_postinst() {
    local subconverter_makefile="./luci-app-subconverter/Makefile"

    [ -f "${subconverter_makefile}" ] || return 0

    if grep -Fq '${IPKG_INSTROOT}/etc/subconverter/subconverter' "${subconverter_makefile}"; then
        echo "【Lin】luci-app-subconverter postinst 已兼容 IPKG_INSTROOT"
        return 0
    fi

    perl -0pi -e 's@define Package/\$\(PKG_NAME\)/postinst\n\s+#!/bin/sh\n\s+chmod 755 /etc/subconverter/subconverter\nendef@define Package/\$(PKG_NAME)/postinst\n    #!/bin/sh\n    [ -f "\${IPKG_INSTROOT}/etc/subconverter/subconverter" ] || exit 0\n    chmod 755 "\${IPKG_INSTROOT}/etc/subconverter/subconverter"\nendef@s' "${subconverter_makefile}"
    echo "【Lin】已修复 luci-app-subconverter postinst 安装根路径：${subconverter_makefile}"
}

update_openvpn_easy_rsa_version() {
    UPDATE_VERSION "openvpn-easy-rsa"
}

# tailscale 的 Makefile 在部分源码树中会带入不兼容 files 路径，这里直接删掉对应引用。
fix_tailscale_makefile() {
    local tailscale_makefile

    tailscale_makefile=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/tailscale/Makefile")
    [ -f "${tailscale_makefile}" ] && sed -i '/\/files/d' "${tailscale_makefile}" && echo "【Lin】tailscale has been fixed!"
}

# rust 在某些环境下使用 ci-llvm=true 会额外触发更重的构建路径，这里改成更稳妥的值。
fix_rust_build() {
    local rust_makefile

    rust_makefile=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/rust/Makefile")
    if [ -f "${rust_makefile}" ]; then
        sed -i 's/ci-llvm=true/ci-llvm=false/g' "${rust_makefile}"
        cd "${package_workdir}" && echo "【Lin】rust has been fixed!"
    fi
}

# diskman 针对 ntfs3 做适配，避免旧依赖名在新树里继续触发编译失败。
fix_diskman_makefile() {
    local diskman_makefile="./luci-app-diskman/applications/luci-app-diskman/Makefile"

    if [ -f "${diskman_makefile}" ]; then
        sed -i 's/fs-ntfs/fs-ntfs3/g' "${diskman_makefile}"
        sed -i '/ntfs-3g-utils /d' "${diskman_makefile}"
        cd "${package_workdir}" && echo "【Lin】diskman has been fixed!"
    fi
}

# pushbot / wechatpush 两组修补都属于“运行时兼容性”修补：
# 主要处理温度读取函数、展示文案，以及与当前设备环境不匹配的逻辑。
fix_pushbot_runtime() {
    local pushbot_dir
    local pushbot_action_file
    local pushbot_feishu_file
    local net_fix_test_del=' https://www.qidian.com https://www.douban.com'

    pushbot_dir=$(find ./*/ -maxdepth 3 -type d -iname "luci-app-pushbot" -prune)
    if [ -n "${pushbot_dir}" ] && [ -f "${pushbot_dir}/root/usr/bin/pushbot/pushbot" ]; then
        pushbot_action_file="${pushbot_dir}/root/usr/bin/pushbot/pushbot"
        sed -i 's/local cputemp=`soc_temp`/local cputemp=`tempinfo`/' "${pushbot_action_file}"
        sed -i 's/CPU：\${cputemp}℃/\${cputemp}/' "${pushbot_action_file}"
        sed -i "s|${net_fix_test_del}||g" "${pushbot_action_file}"
        echo "【Lin】app-pushbot has been fixed"
    fi

    # Feishu 分隔线只保留一个换行，避免出现多余空行。
    #pushbot_feishu_file="${pushbot_dir}/root/usr/bin/pushbot/api/feishu.json"
    #if [ -n "${pushbot_dir}" ] && [ -f "${pushbot_feishu_file}" ]; then
    #    sed -i 's/"str_splitline": "\\\\n\\\\n"/"str_splitline": "\\\\n"/' "${pushbot_feishu_file}"
    #    echo "【Lin】app-pushbot Feishu 格式已修复"
    #fi
}

fix_wechatpush_runtime() {
    local wechatpush_dir
    local wechatpush_bin
    local wechatpush_config

    wechatpush_dir=$(find ./*/ -maxdepth 3 -type d -iname "luci-app-wechatpush" -prune)
    wechatpush_bin="${wechatpush_dir}/root/usr/share/wechatpush/wechatpush"
    if [ -n "${wechatpush_dir}" ] && [ -f "${wechatpush_bin}" ]; then
        sed -i '/^#/!{/^[[:blank:]]*\[ -z "\$1" \] && get_disk/s/^[[:blank:]]*/#&/;}' "${wechatpush_bin}" && echo "【Lin】微信推送去掉硬盘检查"
        sed -i '\|>"\$output_dir/cputemp"|s/soc_temp/tempinfo/g' "${wechatpush_bin}" && echo "【Lin】微信推送添加CPU和WIFI读取"
        sed -i 's/$(translate "CPU:") ${cputemp}℃/${cputemp}/g' "${wechatpush_bin}" && echo "【Lin】微信推送添加CPU和WIFI显示"
        
        wechatpush_config="${current_script_dir}/patch/wechatpush_diy.json"
        [ -f "${wechatpush_config}" ] && cp -p "${wechatpush_config}" "${wechatpush_dir}/root/usr/share/wechatpush/api/diy.json" && \
            echo "【Lin】wechatpush的diy.json成功！"
        wechatpush_diy_feishu="${current_script_dir}/patch/feishu.json"
        [ -f "${wechatpush_diy_feishu}" ] && cp -p "${wechatpush_diy_feishu}" "${wechatpush_dir}/root/usr/share/wechatpush/api/diy_feishu.json" && \
            echo "【Lin】wechatpush的diy_feishu.json备用成功！"
    fi

    if [ -f "${wechatpush_bin}" ]; then
        # 将 dingtalk_url / dingtalk_webhook / feishu_webhook 加入 API key 检查，避免只配对应渠道时误报空 key
        # 在 ${sckey} 前插入，幂等：已含对应变量时跳过
        sed -i '/Please fill in the correct API key/{/jsonpath/{/dingtalk_url/!s/\${sckey}/\${dingtalk_url}\${sckey}/;};}' "${wechatpush_bin}" && echo "【Lin】微信推送API key检查已添加dingtalk_url"
        sed -i '/Please fill in the correct API key/{/jsonpath/{/dingtalk_webhook/!s/\${sckey}/\${dingtalk_webhook}\${sckey}/;};}' "${wechatpush_bin}" && echo "【Lin】微信推送API key检查已添加dingtalk_webhook"
        sed -i '/Please fill in the correct API key/{/jsonpath/{/feishu_webhook/!s/\${sckey}/\${feishu_webhook}\${sckey}/;};}' "${wechatpush_bin}" && echo "【Lin】微信推送API key检查已添加feishu_webhook"
    fi

    dingtalk_json="${current_script_dir}/patch/dingtalk.json"
    to_dingtalk_json="${wechatpush_dir}/root/usr/share/wechatpush/api/dingtalk.json"
    [ -f "${dingtalk_json}" ] && cp -p "${dingtalk_json}" "${to_dingtalk_json}" && echo "【Lin】dingtalk.json已更新"

    feishu_json="${current_script_dir}/patch/feishu.json"
    to_feishu_json="${wechatpush_dir}/root/usr/share/wechatpush/api/feishu.json"
    [ -f "${feishu_json}" ] && cp -p "${feishu_json}" "${to_feishu_json}" && echo "【Lin】feishu.json已更新"
    
}

# 修复 athena-led：@TARGET_ 放在 LUCI_DEPENDS 里不能正确约束包的可见性，
# 需要移到 define Package/config 块中，否则 make defconfig 会删除配置。
fix_athena_led_makefile() {
    local athena_mk

    athena_mk=$(find ./luci-app-athena-led -maxdepth 1 -name "Makefile" 2>/dev/null)
    if [ -n "${athena_mk}" ]; then
        # 1) 从 LUCI_DEPENDS 中移除 @TARGET_ 条件
        perl -i -pe 's{ \@TARGET_\S+}{}' "${athena_mk}"
        # 2) 在 include luci.mk 之前插入 Kconfig config 块，约束设备可见性
        perl -i -0pe 's{(include.*luci\.mk)}{define Package/luci-app-athena-led/config\n\tconfig LUCI_APP_ASTHENA_LED_TARGET\n\t\tbool\n\t\tdefault y if TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02\n\t\tdefault n\nendef\n\n$1}m' "${athena_mk}"
        echo "【Lin】已修复 athena-led 的 @TARGET_ 条件位置"
    fi
}

# homeproxy 这里不是简单替换包，而是预先把规则资源准备到包目录中。
# 这样最终编译出来的镜像会自带一套规则资源，减少首次使用时的初始化成本。
# preload_homeproxy_resources() {
#     local homeproxy_dir
#     local homeproxy_path
#     local homeproxy_rule_dir="./surge"
#     local resource_version

#     homeproxy_dir=$(find . -maxdepth 3 -type d -iname "homeproxy" -prune | head -n 1)
#     [ -n "${homeproxy_dir}" ] || return 0

#     homeproxy_path="${homeproxy_dir}/root/etc/homeproxy"
#     rm -rf "${homeproxy_path}/resources/"*
#     git clone -q --depth=1 --single-branch --branch "release" "https://github.com/Loyalsoldier/surge-rules.git" "${homeproxy_rule_dir}"
#     cd "${homeproxy_rule_dir}" && resource_version=$(git log -1 --pretty=format:'%s' | grep -o "[0-9]*")

#     echo "${resource_version}" | tee china_ip4.ver china_ip6.ver china_list.ver gfw_list.ver
#     awk -F, '/^IP-CIDR,/{print $2 > "china_ip4.txt"} /^IP-CIDR6,/{print $2 > "china_ip6.txt"}' cncidr.txt
#     sed 's/^\.//g' direct.txt > china_list.txt
#     sed 's/^\.//g' gfw.txt > gfw_list.txt
#     mv -f ./{china_*,gfw_list}.{ver,txt} "../${homeproxy_path}/resources/"

#     cd ..
#     rm -rf "${homeproxy_rule_dir}"
#     echo "【Lin】homeproxy date has been updated!"
# }

# 后置修补链的顺序很重要：
# 先修 Makefile / 依赖，再修运行时脚本，再补资源文件。
# 这样可以减少后面的修补建立在“包还没准备好”的状态上。
apply_post_update_fixes() {
    ensure_luci_app_ddns_acl
    fix_quickfile_makefile
    apply_lang_node_prebuilt_fix
    update_openvpn_easy_rsa_version
    fix_tailscale_makefile
    fix_rust_build
    fix_diskman_makefile
}

# 主入口保持极简，只负责串联三个阶段：
# 1. 应用通用包覆盖
# 2. 应用源码配置族专属覆盖（lean 或 iwrt）
# 3. 执行后置修补链
main() {
    resolve_packages_luci_feed_branch
    apply_common_package_overrides

    case "${SOURCE_CONFIG_FAMILY}" in
        iwrt)
            apply_iwrt_package_overrides
            ;;
        lean|*)
            apply_lean_package_overrides
            ;;
    esac

    apply_post_update_fixes
}

main

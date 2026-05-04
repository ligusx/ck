#!/bin/bash
set -e

# 整合备份与还原脚本（兼容ash版本）
# 使用说明:
# 1. 备份模式: ./backup_restore.sh
# 2. 本地还原: ./backup_restore.sh -r /backups/backup_20240101_120000/backup_20240101_120000.aes [-to /path/to/restore] [-pwd 密码]
# 3. 网盘还原: ./backup_restore.sh -r backup_20240101_120000 [-to /path/to/restore] [-pwd 密码]
# 4. 显示备份列表: ./backup_restore.sh -list
# 5. 显示帮助: ./backup_restore.sh -h
# 6. 手动上传指定目录: ./backup_restore.sh -up /path/to/directory [-pwd 密码]
# 7. 删除备份: ./backup_restore.sh -del [序号]
# 8. 自定义密码: 在任何命令后添加 -pwd [密码]
# 9. 备份指定目录并上传: ./backup_restore.sh -sd /path/to/directory [-pwd 密码] [-up]

# 配置参数
TARGET_DIR="" # 默认备份路径
BACKUP_DIR="/home/backups" # 加密备份存储路径
RESTORE_DIR="/data/webdav/restored"  # 默认恢复路径
TEMP_DIR="/home/backups/tmp" # 临时文件处理路径
PASSWORD="" # 默认密码
RCLONE_REMOTE="123pan" # 网盘存储名称
RCLONE_PATH="/123pan" # 网盘存储路径
KEEP_LATEST="3" # 保留加密文件份数
SPLIT_SIZE="100M" #默认加密文件分割大小
SPLIT_SUFFIX=".jpg" #加密文件后缀名
ZSTD_LEVEL="3" # ZSTD压缩等级
COMPRESS_SPEED="250M" # 压缩速度
USER_AGENT="123pan/v2.5.5(Android 13;Xiaomi Mi Max 2)" # 客户端UA伪装
BACKUP_PREFIX="特殊图片和视频_backup_"  # 备份名前缀配置参数
AUTO_UPLOAD="true"  # 设置为 (true/false) 来设置是否自动上传备份到网盘
OBFUSCATE_HEADER="true" # 是否混淆001文件头 (true/false)
FAKE_FILE_HEADER="\xFF\xD8\xFF\xE1\x03\x41\x45\x78\x69\x66\x00\x00\x4D\x4D\x00\x2A"  #文件头混淆

# ============================================================
# 文件头混淆相关函数（偏移量存储方案）
# ============================================================

# 函数: 将原始文件头附加到文件末尾并替换为JPEG头
obfuscate_001_header() {
    local target_file="$1"
    
    if [ ! -f "$target_file" ]; then
        echo "错误: 目标文件不存在: $target_file"
        return 1
    fi
    
    echo "[混淆] 正在处理: $(basename "$target_file")"
    
    # 用 head 读取原始前16字节，速度远快于 dd
    local original_header=$(head -c 16 "$target_file" | xxd -p | tr -d '\n')
    if [ ${#original_header} -ne 32 ]; then
        echo "错误: 无法读取原始文件头 (读取到 ${#original_header} 字符)"
        return 1
    fi
    
    # 检查是否已经被混淆过
    local first_two=$(echo "$original_header" | cut -c1-4)
    if [ "$first_two" = "ffd8" ]; then
        echo "[混淆] 文件已是JPEG头，跳过混淆"
        return 0
    fi
    
    # 记录当前文件大小
    local orig_size=$(wc -c < "$target_file")
    
    # 写入JPEG伪装头（16字节）
    # FF D8 FF E0 00 10 4A 46 49 46 00 01 01 00 00 01
    printf "$FAKE_FILE_HEADER" | \
    dd of="$target_file" bs=16 count=1 conv=notrunc 2>/dev/null || {
        echo "错误: 写入伪装文件头失败"
        return 1
    }
    
    # 在文件末尾追加：原始头(16字节) + 偏移量(8字节小端) + OBFS(4字节)
    # 用 printf 直接写入二进制，一次IO完成
    local offset_le=$(printf '%016x' "$orig_size" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\8\7\6\5\4\3\2\1/')
    printf '%b' "$(echo "$original_header" | sed 's/\(..\)/\\x\1/g')" >> "$target_file"
    printf '%b' "$(echo "$offset_le" | sed 's/\(..\)/\\x\1/g')" >> "$target_file"
    printf 'OBFS' >> "$target_file"
    
    echo "[混淆] 完成: 原始头+偏移量已嵌入文件末尾 (28字节尾部数据)"
    return 0
}

# 函数: 从文件末尾提取原始头并还原
restore_001_header() {
    local target_file="$1"
    
    if [ ! -f "$target_file" ]; then
        echo "错误: 目标文件不存在: $target_file"
        return 1
    fi
    
    # 用 tail 读取末尾4字节魔术标记，速度极快
    local magic=$(tail -c 4 "$target_file")
    if [ "$magic" != "OBFS" ]; then
        echo "[还原] 未找到混淆标记，文件可能未混淆或已还原"
        return 0
    fi
    
    echo "[还原] 检测到混淆标记，正在还原: $(basename "$target_file")"
    
    # 用 tail 一次性读取末尾28字节
    local tail_data=$(tail -c 28 "$target_file" | xxd -p | tr -d '\n')
    
    if [ ${#tail_data} -ne 56 ]; then
        echo "错误: 无法读取尾部数据 (读取到 ${#tail_data} 字符)"
        return 1
    fi
    
    # 提取原始头（前32字符 = 16字节）
    local original_header=$(echo "$tail_data" | cut -c1-32)
    
    # 提取偏移量（接下来16字符 = 8字节，小端序）
    local offset_le=$(echo "$tail_data" | cut -c33-48)
    # 小端转大端：逐字节反转
    local orig_size=0
    local i
    for i in 14 12 10 8 6 4 2 0; do
        local byte=$(echo "$offset_le" | cut -c$((i+1))-$((i+2)))
        orig_size=$((orig_size * 256 + 16#$byte))
    done
    
    # 验证偏移量合理性
    local file_size=$(wc -c < "$target_file")
    if [ "$orig_size" -lt 16 ] || [ "$orig_size" -gt "$file_size" ]; then
        echo "错误: 偏移量异常 ($orig_size)，文件可能已损坏"
        return 1
    fi
    
    # 写入原始头（一次性16字节）
    printf '%b' "$(echo "$original_header" | sed 's/\(..\)/\\x\1/g')" | \
    dd of="$target_file" bs=16 count=1 conv=notrunc 2>/dev/null || {
        echo "错误: 还原文件头失败"
        return 1
    }
    
    # 截断文件，去掉末尾28字节（用 head 比 dd 截断快得多）
    local new_size=$((file_size - 28))
    head -c "$new_size" "$target_file" > "${target_file}.tmp" && \
    mv "${target_file}.tmp" "$target_file" || {
        echo "错误: 截断文件失败"
        return 1
    }
    
    echo "[还原] 完成: 原始头已恢复，尾部数据已移除"
    return 0
}

# 函数: 检查文件是否已被混淆
is_obfuscated() {
    local target_file="$1"
    [ ! -f "$target_file" ] && return 1
    [ $(wc -c < "$target_file") -lt 44 ] && return 1
    [ "$(tail -c 4 "$target_file")" = "OBFS" ]
}

# ============================================================
# 原有函数
# ============================================================

# 清理临时文件函数
cleanup() {
    [ -n "$args_file" ] && rm -f "$args_file"
    [ -n "$local_backups_file" ] && rm -f "$local_backups_file"
    [ -n "$yun_backups_file" ] && rm -f "$yun_backups_file"
}
trap cleanup EXIT

# 检查网盘是否可用
check_rclone_available() {
    if rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
        return 0
    else
        return 1
    fi
}

# 函数: 显示示例命令
show_examples() {
    echo "示例命令:"
    echo "1. 执行备份:"
    echo "   $0 [-pwd 密码]"
    echo ""
    echo "2. 从本地备份还原:"
    echo "   $0 -r $BACKUP_DIR/${BACKUP_PREFIX}20240101_120000/${BACKUP_PREFIX}20240101_120000.aes [-to /custom/restore/path] [-pwd 密码]"
    echo "   或使用序号: $0 -r 1 [-to /custom/restore/path]"
    echo ""
    echo "3. 从网盘备份还原:"
    echo "   $0 -r ${BACKUP_PREFIX}20240101_120000 [-to /custom/restore/path] [-pwd 密码]"
    echo "   或使用序号: $0 -r 5 [-to /custom/restore/path]"
    echo ""
    echo "4. 显示备份列表:"
    echo "   $0 -list"
    echo ""
    echo "5. 删除备份:"
    echo "   $0 -del 1 (删除序号1的备份)"
    echo ""
    echo "6. 手动上传指定目录:"
    echo "   $0 -up /path/to/directory [-pwd 密码]"
    echo ""
    echo "7. 备份指定目录:"
    echo "   $0 -sd /path/to/directory [-pwd 密码] [-up]"
    echo ""
    echo "8. 显示帮助:"
    echo "   $0 -h"
    echo ""
    echo "文件头混淆说明:"
    echo "  - 001文件(或单文件)的OpenSSL头(Salted__)会被替换为JPEG头"
    echo "  - 原始16字节头+偏移量嵌在文件末尾(28字节尾部)"
    echo "  - 还原时自动检测并恢复原始头"
    echo "  - 可通过 OBFUSCATE_HEADER 变量开关此功能"
    exit 0
}

# 函数: 显示用法
show_usage() {
    echo "用法:"
    echo "  $0 [-h] [-list] [-r 备份路径/序号] [-to 恢复路径] [-up 目录] [-del 序号] [-sd 目录] [-pwd 密码]"
    show_examples
    exit 1
}

# 函数: 处理密码参数
handle_password_option() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -pwd)
                if [ -z "$2" ]; then
                    echo "错误: -pwd 参数需要指定密码"
                    exit 1
                fi
                PASSWORD="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
}

get_backup_list() {
    # 使用临时文件存储备份列表
    local_backups_file=$(mktemp)
    yun_backups_file=$(mktemp)
    
    # 本地备份（显示所有目录）
    if [ -d "$BACKUP_DIR" ]; then
        find "$BACKUP_DIR" -maxdepth 1 -type d | grep -v "/backups$" | grep -v "$TEMP_DIR" | sort -r | while IFS= read -r dir; do
            dirname=$(basename "$dir")
            size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            mtime=$(stat -c "%y" "$dir" 2>/dev/null | cut -d'.' -f1)
            printf "%s (大小: %s, 修改时间: %s)\n" "$dirname" "${size:-未知}" "${mtime:-未知}" >> "$local_backups_file"
        done
    fi
    
    # 网盘备份（仅在配置可用时显示）
    if check_rclone_available; then
        rclone lsf "$RCLONE_REMOTE:$RCLONE_PATH" --dirs-only --max-depth 1 2>/dev/null | sort -r | while IFS= read -r dir; do
            info=$(rclone size "$RCLONE_REMOTE:${RCLONE_PATH%/}/${dir}" --json 2>/dev/null)
            size=$(echo "$info" | jq -r '.bytes' 2>/dev/null | awk '{if($1>=1024^3) printf "%.2f GB", $1/1024/1024/1024; else if($1>=1024^2) printf "%.2f MB", $1/1024/1024; else if($1>=1024) printf "%.2f KB", $1/1024; else printf "%d bytes", $1}')
            mtime=$(rclone lsf "$RCLONE_REMOTE:${RCLONE_PATH%/}/${dir}" --format "t" --files-only --max-depth 1 2>/dev/null | head -1 | cut -d';' -f2)
            printf "%s (大小: %s, 修改时间: %s)\n" "$dir" "${size:-未知}" "${mtime:-未知}" >> "$yun_backups_file"
        done
    fi
    
    # 读取到变量
    local_backups=$(cat "$local_backups_file" 2>/dev/null)
    yun_backups=$(cat "$yun_backups_file" 2>/dev/null)
}

# 函数: 显示备份列表（本地和网盘）
show_backup_list() {
    get_backup_list
    
    echo "本地备份列表 (${BACKUP_DIR}):"
    echo "----------------------------------------"
    if [ -n "$local_backups" ]; then
        i=1
        echo "$local_backups" | while IFS= read -r line; do
            printf "%2d. %s\n" "$i" "$line"
            i=$((i+1))
        done
    else
        echo "没有找到本地备份"
    fi
    echo "----------------------------------------"
    echo "使用示例: $0 -r $BACKUP_DIR/${BACKUP_PREFIX}20240101_120000/${BACKUP_PREFIX}20240101_120000.aes [-to /custom/path]"
    echo "或使用序号: $0 -r 1 [-to /custom/path]"
    echo

    echo "网盘备份列表 (${RCLONE_REMOTE}:${RCLONE_PATH}):"
    echo "----------------------------------------"
    if check_rclone_available; then
        if [ -n "$yun_backups" ]; then
            local_count=$(echo "$local_backups" | wc -l)
            i=$((local_count + 1))
            echo "$yun_backups" | while IFS= read -r line; do
                printf "%2d. %s\n" "$i" "$line"
                i=$((i+1))
            done
        else
            echo "没有找到网盘备份"
        fi
    else
        echo "网盘未配置，请先运行 'rclone config' 配置远程存储"
    fi
    echo "----------------------------------------"
    echo "使用示例: $0 -r ${BACKUP_PREFIX}20240101_120000 [-to /custom/path]"
    echo "或使用序号: $0 -r $(( $(echo "$local_backups" | wc -l) + 1 )) [-to /custom/path]"
}

# 函数: 根据序号获取备份名称
get_backup_by_index() {
    local index="$1"
    get_backup_list
    
    local local_count=$(echo "$local_backups" | wc -l)
    
    if [ "$index" -le "$local_count" ]; then
        # 本地备份
        echo "$local_backups" | sed -n "${index}p" | sed -E 's/^[0-9]+\. //' | cut -d' ' -f1
    else
        # 网盘备份
        local yun_index=$((index - local_count))
        echo "$yun_backups" | sed -n "${yun_index}p" | cut -d' ' -f1
    fi

    # 去除尾部的斜杠
    echo "$result" | sed 's:/$::'
}

# 函数: 自动判断备份位置
determine_backup_location() {
    local backup_arg="$1"
    
    # 如果是数字序号
    if echo "$backup_arg" | grep -q '^[0-9]\+$'; then
        backup_name=$(get_backup_by_index "$backup_arg")
        [ -z "$backup_name" ] && { echo "无效的序号: $backup_arg"; exit 1; }
        
        # 去除尾部的斜杠
        backup_name=$(echo "$backup_name" | sed 's:/$::')

        # 检查是本地还是网盘
        if [ -d "${BACKUP_DIR}/${backup_name}" ]; then
            echo "local"
        else
            echo "yun"
        fi
    else
        # 如果是完整路径
        if echo "$backup_arg" | grep -q "^${BACKUP_DIR}"; then
            echo "local"
        elif [ -f "$backup_arg" ] || [ -d "$backup_arg" ]; then
            echo "local"
        else
            # 检查是否是网盘备份
            if check_rclone_available && rclone lsf "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_arg}" >/dev/null 2>&1; then
                echo "yun"
            else
                echo "无法确定备份位置: $backup_arg"
                exit 1
            fi
        fi
    fi
}

# 函数: 检查并安装依赖
check_dependencies() {
    local dependencies="tar zstd pv rclone jq openssl xxd"
    local missing=""
    
    for dep in $dependencies; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing="$missing $dep"
        fi
    done
    
    # 额外检查 coreutils 中的常用命令
    for cmd in md5sum sha256sum dd stat; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    
    # 额外检查 findutils 中的 find 命令
    if ! command -v "find" >/dev/null 2>&1; then
        missing="$missing find"
    fi
    
    if [ -n "$missing" ]; then
        echo "缺少依赖: $missing"
        
        if [ -f /etc/alpine-release ]; then
            echo "检测到 Alpine 系统，使用 apk 安装"
            apk add --no-cache $missing || { echo "依赖安装失败!"; exit 1; }
        
        elif [ -f /etc/debian_version ]; then
            echo "检测到 Debian/Ubuntu 系统，使用 apt 安装"
            apt-get update -y
            apt-get install -y $missing coreutils findutils 2>/dev/null || {
                apt-get install -y $missing || { echo "依赖安装失败!"; exit 1; }
            }
        
        elif [ -f /etc/redhat-release ] || [ -f /etc/centos-release ]; then
            if command -v dnf >/dev/null 2>&1; then
                echo "检测到 RHEL/CentOS/Fedora 系统，使用 dnf 安装"
                dnf install -y $missing coreutils findutils || { echo "依赖安装失败!"; exit 1; }
            else
                echo "检测到 RHEL/CentOS 系统，使用 yum 安装"
                yum install -y $missing coreutils findutils || { echo "依赖安装失败!"; exit 1; }
            fi
        
        else
            echo "未知系统，请手动安装以下依赖: $missing"
            exit 1
        fi
    fi
}

# 函数: 检查 rclone 是否已配置远程
check_rclone_config() {
    local config_file=""
    
    # 检查可能的配置文件位置
    if [ -f "$HOME/.config/rclone/rclone.conf" ]; then
        config_file="$HOME/.config/rclone/rclone.conf"
    elif [ -f "/root/.config/rclone/rclone.conf" ]; then
        config_file="/root/.config/rclone/rclone.conf"
    fi
    
    if [ -z "$config_file" ]; then
        # 配置文件不存在，提示用户配置
        echo "[!] rclone 配置文件不存在"
        echo ">>> 10 秒内按 Enter 进入 rclone 配置向导，否则自动跳过并继续 <<<"

        if read -t 10 -p "" user_input; then
            echo "[*] 启动 rclone 配置向导..."
            rclone config
            echo "[+] rclone 配置完成"
            
            # 检查配置是否成功
            if check_rclone_available; then
                echo "[+] 网盘配置成功，网盘功能可用"
            else
                echo "[!] 警告: 网盘配置可能不完整，网盘功能不可用"
            fi
        else
            echo "[!] 超时未选择，跳过 rclone 配置，网盘功能不可用"
        fi
    else
        # 配置文件存在，检查是否有远程配置
        if check_rclone_available; then
            echo "[+] 已检测到 rclone 配置: ${RCLONE_REMOTE}"
        else
            echo "[!] 警告: rclone 配置文件存在但未配置远程 ${RCLONE_REMOTE}，网盘功能不可用"
        fi
    fi
}

# 函数: 使用dd分割文件（自定义后缀，去除.aes）
split_with_dd() {
    local input_file="$1"
    local output_prefix="$2"
    local chunk_size="$3"
    local suffix="$4"
    
    # 去掉output_prefix中的.aes后缀（如果有的话）
    local clean_prefix="${output_prefix%.aes}"
    
    # 获取文件总大小(字节)
    local total_size=$(wc -c < "$input_file")
    local block_size=$(echo "$chunk_size" | awk '/[0-9]$/{print $1; next} /k$/{print $1*1024; next} /M$/{print $1*1024*1024; next} /G$/{print $1*1024*1024*1024; next}')
    
    # 清空可能存在的旧分割文件
    rm -f "${clean_prefix}."[0-9][0-9][0-9]"${suffix}"
    rm -f "${clean_prefix}${suffix}"
    
    # 检查是否需要分割
    if [ $total_size -le $block_size ]; then
        local output_file="${clean_prefix}${suffix}"
        cp "$input_file" "$output_file" || { echo "创建单文件失败"; return 1; }
        echo "文件小于分割大小，已创建单文件: $output_file"
        return 0
    fi
    
    local count=1
    local offset=0
    
    # 循环分割文件
    while [ $offset -lt $total_size ]; do
        local output_file="${clean_prefix}.$(printf "%03d" $count)${suffix}"
        dd if="$input_file" of="$output_file" bs="$block_size" skip=$((count-1)) count=1 2>/dev/null || {
            echo "分割文件失败"; return 1
        }
        count=$((count + 1))
        offset=$(( (count-1) * block_size ))
    done
    
    echo "已分割为 $((count-1)) 个文件"
}

# 函数: 校验分割文件（带详细输出）
verify_split_files() {
    local backup_dir="$1"
    local backup_name="$2"
    
    echo "正在校验分割文件..."
    
    # 检查校验文件是否存在
    if [ ! -f "$backup_dir/checksums.md5" ]; then
        echo "警告: 找不到MD5校验文件，跳过MD5校验"
    else
        echo "正在进行MD5校验:"
        local md5_result_file=$(mktemp)
        (cd "$backup_dir" && md5sum -c checksums.md5 2>/dev/null > "$md5_result_file")
        
        grep -E "(${SPLIT_SUFFIX})" "$md5_result_file" | \
        sort -V | \
        while read -r line; do
            local file=$(echo "$line" | awk -F: '{print $1}' | sed 's|^\./||;s|^\./\./||')
            local status=$(echo "$line" | cut -d: -f2-)
            printf "  %-40s %s\n" "$file" "$status"
        done
        
        if grep -q "FAILED" "$md5_result_file"; then
            rm -f "$md5_result_file"
            echo "错误: MD5校验失败"
            return 1
        fi
        rm -f "$md5_result_file"
    fi
    
    # SHA256校验
    if [ ! -f "$backup_dir/checksums.sha256" ]; then
        echo "警告: 找不到SHA256校验文件，跳过SHA256校验"
    else
        echo "正在进行SHA256校验:"
        local sha_result_file=$(mktemp)
        (cd "$backup_dir" && sha256sum -c checksums.sha256 2>/dev/null > "$sha_result_file")
        
        grep -E "(${SPLIT_SUFFIX})" "$sha_result_file" | \
        sort -V | \
        while read -r line; do
            local file=$(echo "$line" | awk -F: '{print $1}' | sed 's|^\./||;s|^\./\./||')
            local status=$(echo "$line" | cut -d: -f2-)
            printf "  %-40s %s\n" "$file" "$status"
        done
        
        if grep -q "FAILED" "$sha_result_file"; then
            rm -f "$sha_result_file"
            echo "错误: SHA256校验失败"
            return 1
        fi
        rm -f "$sha_result_file"
    fi
    
    echo "所有分割文件校验通过"
    return 0
}

# 函数: 比较本地和远程文件差异
compare_and_download() {
    local remote_dir="$1"
    local local_dir="$2"
    
    # 获取远程文件列表
    remote_files=$(rclone lsf "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${remote_dir}" --files-only --format "p" 2>/dev/null)
    
    # 检查本地文件
    missing_files=""
    for file in $remote_files; do
        if [ ! -f "${local_dir}/${file}" ]; then
            missing_files="${missing_files} ${file}"
        fi
    done
    
    # 如果有缺失文件，只下载缺失的文件
    if [ -n "$missing_files" ]; then
        echo "发现 $(echo "$missing_files" | wc -w) 个文件需要下载..."
        for file in $missing_files; do
            echo "正在下载缺失文件: $file"
            rclone copy "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${remote_dir}/${file}" "$local_dir" \
            --user-agent "$USER_AGENT" 2>/dev/null || { echo "下载失败: $file"; return 1; }
        done
    else
        echo "所有文件已存在本地，无需下载"
    fi
    
    return 0
}

# 函数: 备份流程
perform_backup() {
    local target_dir="$1"
    local backup_name="${2:-${BACKUP_PREFIX}$(date +"%Y%m%d_%H%M%S")}"
    local upload_after_backup="${3:-false}"
    
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始备份流程 (密码: ${PASSWORD:0:2}****)"
    
    backup_folder="${BACKUP_DIR}/${backup_name}"
    mkdir -p "$backup_folder"
    zst_file="${backup_folder}/${backup_name}"
    enc_file="${zst_file}.aes"
    
    # 压缩
    echo "正在压缩文件夹..."
    tar -cf - -C "$(dirname "$target_dir")" "$(basename "$target_dir")" | \
    pv -q -L $COMPRESS_SPEED | zstd -$ZSTD_LEVEL -q -o "$zst_file" || {
        echo "压缩失败!"; rm -f "$zst_file"; return 1
    }
    
    # 校验
    echo "正在校验压缩文件..."
    zstd -t "$zst_file" || { echo "压缩文件校验失败!"; rm -f "$zst_file"; return 1; }
    
    # 加密
    echo "正在加密文件..."
    openssl enc -aes256 -pbkdf2 -in "$zst_file" -out "$enc_file" -pass pass:"$PASSWORD" || {
        echo "加密失败!"; rm -f "$enc_file"; return 1
    }
    rm -f "$zst_file"
    
    # 分割
    echo "正在分割加密文件..."
    split_with_dd "$enc_file" "$enc_file" "$SPLIT_SIZE" "$SPLIT_SUFFIX" || {
        echo "文件分割失败!"; return 1
    }
    [ -f "${enc_file%.aes}${SPLIT_SUFFIX}" ] || rm -f "$enc_file"
    
    # ============================================================
    # 新增：001文件头混淆（偏移量存储方案）
    # ============================================================
    if [ "$OBFUSCATE_HEADER" = "true" ]; then
        local clean_prefix="${enc_file%.aes}"
        local file_001="${clean_prefix}.001${SPLIT_SUFFIX}"
        
        if [ -f "$file_001" ]; then
            # 有分片，混淆001
            obfuscate_001_header "$file_001" || {
                echo "001文件头混淆失败!"
                return 1
            }
        else
            # 没有分片（文件小于分割大小），检查单文件
            local single_file="${clean_prefix}${SPLIT_SUFFIX}"
            if [ -f "$single_file" ]; then
                echo "[混淆] 文件未分割，直接混淆单文件头..."
                obfuscate_001_header "$single_file" || {
                    echo "单文件头混淆失败!"
                    return 1
                }
            fi
        fi
        echo "[混淆] 文件头混淆处理完成"
    else
        echo "[混淆] 文件头混淆已禁用 (OBFUSCATE_HEADER=false)"
    fi
    
    # 校验文件（针对混淆后的文件生成校验和）
    echo "正在创建校验文件..."
    ( cd "$backup_folder" && \
      rm -f checksums.md5 checksums.sha256 && \
      for f in *; do
          [ "$f" != "checksums.md5" ] && [ "$f" != "checksums.sha256" ] && \
          md5sum "$f" >> checksums.md5 2>/dev/null
      done && \
      sha256sum * 2>/dev/null | grep -v checksums > checksums.sha256 ) || \
      { echo "创建校验文件失败!"; return 1; }
    
    # 如果指定了上传，则上传到网盘
    if [ "$upload_after_backup" = "true" ]; then
        if check_rclone_available; then
            echo "正在上传到网盘..."
            rclone mkdir "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_name}" 2>/dev/null && \
            rclone copy "$backup_folder" "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_name}" 2>/dev/null || {
                echo "上传失败!"; return 1
            }
        else
            echo "[!] 跳过上传：网盘未配置"
        fi
    fi
    
    # 清理旧备份（仅清理带配置前缀的）
    echo "清理旧备份（保留最新${KEEP_LATEST}份，仅处理${BACKUP_PREFIX}前缀）..."
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "${BACKUP_PREFIX}*" | \
    grep -v "${backup_name}" | grep -v "$TEMP_DIR" | sort -r | \
    awk -v keep="$KEEP_LATEST" 'NR > keep {print $0}' | \
    while read -r dir; do rm -rf "$dir"; done

    # 网盘清理（仅在配置可用时）
    if check_rclone_available; then
        rclone lsd "${RCLONE_REMOTE}:${RCLONE_PATH}" 2>/dev/null | \
        awk '{print $5}' | grep "^${BACKUP_PREFIX}" | \
        grep -v "${backup_name}" | sort -r | \
        awk -v keep="$KEEP_LATEST" 'NR > keep {print $0}' | \
        while read -r dir; do 
            rclone purge "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${dir}" 2>/dev/null
        done
    fi
    
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 备份完成: ${backup_name}"
}

# 函数: 手动上传指定目录
manual_upload() {
    local dir_to_backup="$1"
    [ ! -d "$dir_to_backup" ] && { echo "目录不存在: $dir_to_backup"; exit 1; }
    
    # 检查网盘配置
    if ! check_rclone_available; then
        echo "错误: 网盘未配置，无法上传"
        echo "请先运行 'rclone config' 配置远程存储"
        exit 1
    fi
    
    echo "开始手动上传目录: $dir_to_backup (密码: ${PASSWORD:0:2}****)"
    
    # 使用目录名作为备份名
    local dir_name=$(basename "$dir_to_backup")
    timestamp=$(date +"%Y%m%d_%H%M%S")
    backup_name="${dir_name}_${timestamp}"
    
    echo "正在执行备份: $backup_name"
    perform_backup "$dir_to_backup" "$backup_name" "true" || exit 1
    echo "手动上传完成"
}

# 函数: 备份指定目录
backup_specific_directory() {
    local dir_to_backup="$1"
    local upload_after_backup="$2"
    [ ! -d "$dir_to_backup" ] && { echo "目录不存在: $dir_to_backup"; exit 1; }
    
    # 如果要求上传，检查网盘配置
    if [ "$upload_after_backup" = "true" ]; then
        if ! check_rclone_available; then
            echo "错误: 网盘未配置，无法上传"
            echo "请先运行 'rclone config' 配置远程存储"
            exit 1
        fi
    fi
    
    echo "开始备份指定目录: $dir_to_backup (密码: ${PASSWORD:0:2}****)"
    
    # 使用目录名作为备份名
    local dir_name=$(basename "$dir_to_backup")
    timestamp=$(date +"%Y%m%d_%H%M%S")
    backup_name="${dir_name}_${timestamp}"
    
    echo "正在执行备份: $backup_name"
    perform_backup "$dir_to_backup" "$backup_name" "$upload_after_backup" || exit 1
    echo "指定目录备份完成"
}

# 函数: 删除备份
delete_backup() {
    local index="$1"
    backup_name=$(get_backup_by_index "$index")
    [ -z "$backup_name" ] && { echo "无效的序号: $index"; exit 1; }
    
    if [ -d "${BACKUP_DIR}/${backup_name}" ]; then
        echo "正在删除本地备份: $backup_name"
        rm -rf "${BACKUP_DIR}/${backup_name}" || { echo "删除失败"; exit 1; }
        echo "本地备份删除成功"
    else
        if check_rclone_available; then
            echo "正在删除网盘备份: $backup_name"
            rclone purge "$RCLONE_REMOTE:${RCLONE_PATH%/}/${backup_name}" 2>/dev/null || { echo "删除失败"; exit 1; }
            echo "网盘备份删除成功"
        else
            echo "错误: 网盘未配置，无法删除网盘备份"
            exit 1
        fi
    fi
}

# 函数: 还原流程
perform_restore() {
    local backup_arg="$1"
    local restore_to="${2:-$RESTORE_DIR}"
    
    # 自动判断备份位置
    local mode=$(determine_backup_location "$backup_arg")
    
    # 检查是否是数字序号
    if echo "$backup_arg" | grep -q '^[0-9]\+$'; then
        backup_name=$(get_backup_by_index "$backup_arg")
        [ -z "$backup_name" ] && { echo "无效的序号: $backup_arg"; exit 1; }
        echo "使用序号 $backup_arg 对应的备份: $backup_name"
    else
        backup_name="$backup_arg"
    fi
    
    # 创建恢复目录
    mkdir -p "$restore_to" || { echo "无法创建恢复目录: $restore_to"; exit 1; }
    
    if [ "$mode" = "yun" ]; then
        # 检查网盘配置
        if ! check_rclone_available; then
            echo "错误: 网盘未配置，无法从网盘还原"
            exit 1
        fi
        # 去除backup_name尾部的斜杠
        backup_name=$(echo "$backup_name" | sed 's:/$::')

        # 网盘还原模式
        backup_dir="${TEMP_DIR}/${backup_name}"
        backup_prefix="${backup_dir}/${backup_name}"
        
        echo "从网盘下载备份文件: ${backup_name} (密码: ${PASSWORD:0:2}****)"
        mkdir -p "$backup_dir"
        
        # 先检查本地是否已有部分文件
        if [ -d "$backup_dir" ] && [ "$(ls -1 "$backup_dir" 2>/dev/null | wc -l)" -gt 0 ]; then
            echo "发现本地已有部分文件，开始对比并下载缺失文件..."
            compare_and_download "$backup_name" "$backup_dir" || { echo "差异下载失败!"; exit 1; }
        else
            echo "正在从网盘下载备份文件..."
            rclone copy "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_name}" "$backup_dir" \
            --user-agent "$USER_AGENT" 2>/dev/null || { echo "下载失败!"; exit 1; }
        fi
        
        # 检查分割文件
        if ! ls "${backup_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" >/dev/null 2>&1 && \
           [ ! -f "${backup_prefix}${SPLIT_SUFFIX}" ]; then
            backup_prefix="${backup_dir}/${backup_name}.aes"
            if ! ls "${backup_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" >/dev/null 2>&1 && \
               [ ! -f "${backup_prefix}${SPLIT_SUFFIX}" ]; then
                echo "找不到备份文件"; exit 1
            fi
            echo "检测到旧格式备份文件（含.aes）"
        fi
    else
        # 本地还原模式
        if echo "$backup_arg" | grep -q '^[0-9]\+$'; then
            backup_dir="${BACKUP_DIR}/${backup_name}"
            backup_prefix="${backup_dir}/${backup_name}"
        else
            backup_prefix="$backup_arg"
            backup_dir=$(dirname "$backup_prefix")
            backup_name=$(basename "$backup_prefix" .aes)
            if [ "$backup_name" = "$(basename "$backup_prefix")" ]; then
                backup_name=$(basename "$backup_prefix")
            fi
        fi
        
        # 检查分割文件
        if ! ls "${backup_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" >/dev/null 2>&1 && \
           [ ! -f "${backup_prefix}${SPLIT_SUFFIX}" ]; then
            if [ "$backup_prefix" != "${backup_prefix}.aes" ]; then
                old_prefix="${backup_prefix}.aes"
                if ls "${old_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" >/dev/null 2>&1 || \
                   [ -f "${old_prefix}${SPLIT_SUFFIX}" ]; then
                    echo "检测到旧格式备份文件（含.aes），兼容处理中..."
                    backup_prefix="$old_prefix"
                else
                    echo "找不到备份文件"; exit 1
                fi
            else
                echo "找不到备份文件"; exit 1
            fi
        fi
    fi

    mkdir -p "$TEMP_DIR"

    # ============================================================
    # 检查是否需要还原001文件头（决定是否跳过校验）
    # ============================================================
    local backup_prefix_noext="${backup_prefix%.aes}"
    
    local file_001=""
    [ -f "${backup_prefix_noext}.001${SPLIT_SUFFIX}" ] && file_001="${backup_prefix_noext}.001${SPLIT_SUFFIX}"
    [ -z "$file_001" ] && [ -f "${backup_prefix}.001${SPLIT_SUFFIX}" ] && file_001="${backup_prefix}.001${SPLIT_SUFFIX}"
    
    local need_restore=false
    if [ -n "$file_001" ] && [ -f "$file_001" ]; then
        if is_obfuscated "$file_001"; then
            need_restore=true
        fi
    else
        # 检查单文件情况
        local single_file=""
        [ -f "${backup_prefix_noext}${SPLIT_SUFFIX}" ] && single_file="${backup_prefix_noext}${SPLIT_SUFFIX}"
        [ -z "$single_file" ] && [ -f "${backup_prefix}${SPLIT_SUFFIX}" ] && single_file="${backup_prefix}${SPLIT_SUFFIX}"
        
        if [ -n "$single_file" ] && [ -f "$single_file" ] && is_obfuscated "$single_file"; then
            need_restore=true
        fi
    fi

    # ============================================================
    # 仅首次还原时校验（001仍是混淆状态，与生成校验和时一致）
    # 已经还原过的跳过校验
    # ============================================================
    if [ "$need_restore" = true ]; then
        echo "[校验] 检测到001文件仍为混淆状态，执行完整性校验..."
        verify_split_files "$backup_dir" "$backup_name" || { echo "文件校验失败，无法继续还原"; exit 1; }
    else
        echo "[校验] 001文件已还原或无混淆，跳过校验"
    fi

    # ============================================================
    # 还原001文件头（仅在需要时）
    # ============================================================
    if [ "$need_restore" = true ] && [ -n "$file_001" ] && [ -f "$file_001" ]; then
        echo "[还原] 校验通过，正在还原001文件头..."
        restore_001_header "$file_001" || {
            echo "错误: 还原001文件头失败!"
            exit 1
        }
        echo "[还原] 001文件头还原完成"
    elif [ "$need_restore" = true ] && [ -n "$single_file" ] && [ -f "$single_file" ]; then
        echo "[还原] 校验通过，正在还原单文件头..."
        restore_001_header "$single_file" || {
            echo "错误: 还原文件头失败!"
            exit 1
        }
        echo "[还原] 单文件头还原完成"
    fi

    # ============================================================
    # 合并分割文件
    # ============================================================
    enc_file="${TEMP_DIR}/${backup_name}.aes"
    if ls "${backup_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" >/dev/null 2>&1 || \
       ls "${backup_prefix_noext}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" >/dev/null 2>&1; then
        echo "正在合并分割文件..."
        : > "$enc_file"
        # 确定使用哪个前缀
        local merge_prefix="$backup_prefix"
        [ ! -f "${merge_prefix}.001${SPLIT_SUFFIX}" ] && merge_prefix="$backup_prefix_noext"
        
        for part in $(ls -1 "${merge_prefix}."[0-9][0-9][0-9]"${SPLIT_SUFFIX}" | sort -t. -k3 -n); do
            cat "$part" >> "$enc_file" || { echo "合并失败"; exit 1; }
        done
    elif [ -f "${backup_prefix}${SPLIT_SUFFIX}" ]; then
        echo "使用未分割的完整备份文件"
        cp "${backup_prefix}${SPLIT_SUFFIX}" "$enc_file" || { echo "复制失败"; exit 1; }
    elif [ -f "${backup_prefix_noext}${SPLIT_SUFFIX}" ]; then
        echo "使用未分割的完整备份文件"
        cp "${backup_prefix_noext}${SPLIT_SUFFIX}" "$enc_file" || { echo "复制失败"; exit 1; }
    else
        echo "找不到备份文件"; exit 1
    fi

    # 解密
    echo "正在解密文件..."
    zst_file="${enc_file%.aes}"
    openssl enc -d -aes256 -pbkdf2 -in "$enc_file" -out "$zst_file" -pass pass:"$PASSWORD" || {
        echo "解密失败!"; rm -f "$zst_file"; exit 1
    }
    rm -f "$enc_file"

    # 解压
    echo "正在解压zst文件到: $restore_to ..."
    zstd -d -c "$zst_file" | tar -x -C "$restore_to" || {
        echo "解压失败!"; rm -f "$zst_file"; exit 1
    }
    rm -f "$zst_file"

    # 清理
    [ "$mode" = "yun" ] && rm -rf "$backup_dir"

    echo "还原成功! 文件已恢复到: $restore_to"
}

# ============================================================
# 主程序
# ============================================================

# 首先处理密码参数
handle_password_option "$@"

# 使用临时文件处理参数
args_file=$(mktemp)
while [ $# -gt 0 ]; do
    case "$1" in
        -pwd)
            shift 2
            ;;
        *)
            echo "$1" >> "$args_file"
            shift
            ;;
    esac
done
set -- $(cat "$args_file")
rm -f "$args_file"

check_dependencies
check_rclone_config

# 解析参数
while [ $# -gt 0 ]; do
    case "$1" in
        "")
            perform_backup "$TARGET_DIR" "" "$AUTO_UPLOAD"
            exit 0
            ;;
        -r)
            shift
            restore_arg=""
            restore_to="$RESTORE_DIR"
            
            [ $# -eq 0 ] && { echo "必须指定备份路径或序号"; show_usage; }
            restore_arg="$1"
            shift
            
            # 处理 -to 参数
            if [ "$1" = "-to" ]; then
                shift
                [ $# -eq 0 ] && { echo "必须指定恢复路径"; show_usage; }
                restore_to="$1"
                shift
            fi
            
            perform_restore "$restore_arg" "$restore_to"
            exit 0
            ;;
        -list)
            show_backup_list
            exit 0
            ;;
        -h|--help)
            show_examples
            exit 0
            ;;
        -up)
            shift
            if ! check_rclone_available; then
                echo "错误: 网盘未配置，无法上传"
                echo "请先运行 'rclone config' 配置远程存储"
                exit 1
            fi
            
            if [ $# -gt 0 ] && [ -d "$1" ]; then
                dir_to_upload="$1"
                shift
            else
                echo "未指定有效目录，自动查找最新备份..."
                latest_backup=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "${BACKUP_PREFIX}*" | grep -v "$TEMP_DIR" | sort -r | head -n 1)
                
                if [ -z "$latest_backup" ]; then
                    echo "错误: 找不到可用的备份目录"
                    echo "用法: $0 -up [备份目录路径]"
                    echo "示例: $0 -up /backups/特殊图片和视频_20260503_131314"
                    exit 1
                fi
                dir_to_upload="$latest_backup"
                echo "找到最新备份: $dir_to_upload"
            fi
            
            backup_name=$(basename "$dir_to_upload")
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始上传备份: $backup_name"
            
            if [ -z "$(ls -A "$dir_to_upload" 2>/dev/null)" ]; then
                echo "错误: 备份目录为空: $dir_to_upload"
                exit 1
            fi
            
            echo "目录内容:"
            ls -lh "$dir_to_upload" | head -10
            if [ "$(ls -1 "$dir_to_upload" | wc -l)" -gt 10 ]; then
                echo "... 还有 $(($(ls -1 "$dir_to_upload" | wc -l) - 10)) 个文件"
            fi
            
            echo "正在上传到网盘..."
            if rclone mkdir "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_name}" 2>/dev/null; then
                echo "创建远程目录成功"
            fi
            
            if rclone copy "$dir_to_upload" "${RCLONE_REMOTE}:${RCLONE_PATH%/}/${backup_name}" \
                --progress \
                --user-agent "$USER_AGENT" 2>/dev/null; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] 上传完成: ${backup_name}"
            else
                echo "上传失败!"
                exit 1
            fi
            exit 0
            ;;

        -del)
            shift
            [ $# -eq 0 ] && { echo "必须指定序号"; show_usage; }
            delete_backup "$1"
            exit 0
            ;;
        -sd)
            shift
            [ $# -eq 0 ] && { echo "必须指定目录路径"; show_usage; }
            dir_to_backup="$1"
            shift
            
            upload_after_backup="false"
            if [ "$1" = "-up" ]; then
                upload_after_backup="true"
                shift
            fi
            
            backup_specific_directory "$dir_to_backup" "$upload_after_backup"
            exit 0
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
done

# 默认执行备份
perform_backup "$TARGET_DIR" "" "$AUTO_UPLOAD"

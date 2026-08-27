#!/bin/bash
#
# 图片功能依赖自举：为 TinyPNG / WebP 转换静默准备运行依赖
# 用法: ensure_image_dependencies.sh [--check]
#   （无参数） 检测并静默安装缺失依赖：cwebp、python3 requests/urllib3
#   --check    只检测不安装：全部就绪退出 0，有缺失退出 1
#   -h/--help  显示本说明
#
# 说明：
#   - WebP 转换依赖 cwebp（brew install webp）；
#   - TinyPNG 依赖 python3 的 requests/urllib3；
#   - 依赖已就绪时本脚本只做检测，秒级返回，不会触发网络请求。

set -u

check_only=0
case "${1:-}" in
    "")
        ;;
    --check)
        check_only=1
        ;;
    -h|--help)
        sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "未知参数: $1（支持 --check / --help）"
        exit 2
        ;;
esac

# GUI 启动环境下 PATH 可能极简，补上 Homebrew 与系统常见目录
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

BREW=""
if command -v brew >/dev/null 2>&1; then
    BREW="$(command -v brew)"
elif [ -x /opt/homebrew/bin/brew ]; then
    BREW=/opt/homebrew/bin/brew
elif [ -x /usr/local/bin/brew ]; then
    BREW=/usr/local/bin/brew
fi

cwebp_ready() {
    command -v cwebp >/dev/null 2>&1 && cwebp -version >/dev/null 2>&1
}

ensure_cwebp() {
    if cwebp_ready; then
        return 0
    fi
    if [ "$check_only" -eq 1 ]; then
        return 1
    fi
    if [ -z "$BREW" ]; then
        echo "[deps] 未找到 Homebrew，无法自动安装 cwebp，请手动执行: brew install webp"
        return 1
    fi
    echo "[deps] 正在通过 Homebrew 静默安装 webp ..."
    "$BREW" install webp >/dev/null 2>&1
    if cwebp_ready; then
        echo "[deps] cwebp 已就绪"
        return 0
    fi
    # 动态库缺失（如 libtiff 版本不匹配）时补装后重试一次
    echo "[deps] cwebp 运行异常，尝试补齐动态库依赖 ..."
    "$BREW" install libtiff >/dev/null 2>&1
    if cwebp_ready; then
        echo "[deps] cwebp 已就绪"
        return 0
    fi
    echo "[deps] cwebp 安装失败，请手动执行: brew install webp"
    return 1
}

python_deps_ready() {
    python3 -c "import requests, urllib3" >/dev/null 2>&1
}

ensure_python_deps() {
    if python_deps_ready; then
        return 0
    fi
    if [ "$check_only" -eq 1 ]; then
        return 1
    fi
    echo "[deps] 正在安装 python3 依赖 requests/urllib3 ..."
    python3 -m pip install --quiet requests urllib3 >/dev/null 2>&1 \
        || python3 -m pip install --quiet --user requests urllib3 >/dev/null 2>&1
    if python_deps_ready; then
        echo "[deps] python3 依赖已就绪"
        return 0
    fi
    echo "[deps] python3 依赖安装失败，TinyPNG 压缩时可能需要手动执行: python3 -m pip install requests urllib3"
    return 1
}

failures=0
ensure_cwebp || failures=$((failures + 1))
ensure_python_deps || failures=$((failures + 1))

if [ "$failures" -gt 0 ]; then
    exit 1
fi
exit 0

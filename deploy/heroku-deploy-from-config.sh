#!/usr/bin/env bash
# deploy/heroku-deploy-from-config.sh
# 目标：
#   1. 构建与业务运行时配置解耦的 Heroku 容器镜像
#   2. 清理遗留的 SERVER_PORT 配置，统一交给 Heroku 运行时 PORT
#   3. 提供可重复执行的构建、推送、发布链路

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "缺少命令: $1"
        exit 1
    fi
}

if [ ! -f "Dockerfile.heroku" ]; then
    echo "请在项目根目录执行脚本，且目录下必须存在 Dockerfile.heroku"
    exit 1
fi

require_command heroku
require_command podman
require_command curl

APP_NAME="${1:-openc}"
APP_NAME="$(printf '%s' "${APP_NAME}" | tr -d '[:space:]')"
if [ -z "${APP_NAME}" ]; then
    echo "应用名不能为空"
    exit 1
fi

LOCAL_IMAGE_TAG="${APP_NAME}-heroku:local"
REMOTE_IMAGE_TAG="registry.heroku.com/${APP_NAME}/web"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "开始部署 Heroku 容器"
echo "应用: ${APP_NAME}"
echo "项目目录: ${PROJECT_ROOT}"

echo
echo "校验 Heroku 应用..."
if ! heroku info -a "${APP_NAME}" >/dev/null 2>&1; then
    echo "Heroku 应用不存在: ${APP_NAME}"
    exit 1
fi

get_config() {
    heroku config:get "$1" -a "${APP_NAME}" 2>/dev/null | tr -d '\r'
}

ensure_runtime_config() {
    local server_host
    local bind_host
    local stale_server_port
    local config_yaml_b64
    local installed_flag
    local redis_conf_b64

    server_host="$(get_config SERVER_HOST)"
    bind_host="$(get_config BIND_HOST)"
    stale_server_port="$(get_config SERVER_PORT)"
    config_yaml_b64="$(get_config SUB2API_CONFIG_YAML_B64)"
    installed_flag="$(get_config SUB2API_INSTALLED)"
    redis_conf_b64="$(get_config SUB2API_REDIS_CONF_B64)"

    if [ -z "${server_host}" ]; then
        if [ -n "${bind_host}" ]; then
            server_host="${bind_host}"
            echo "迁移遗留 BIND_HOST -> SERVER_HOST=${server_host}"
        else
            server_host="0.0.0.0"
            echo "补齐运行时 SERVER_HOST=${server_host}"
        fi
        heroku config:set SERVER_HOST="${server_host}" -a "${APP_NAME}" >/dev/null
    else
        echo "保留运行时 SERVER_HOST=${server_host}"
    fi

    if [ -n "${bind_host}" ]; then
        echo "清理遗留 BIND_HOST=${bind_host}"
        heroku config:unset BIND_HOST -a "${APP_NAME}" >/dev/null
    else
        echo "未发现遗留 BIND_HOST"
    fi

    if [ -n "${stale_server_port}" ]; then
        echo "清理遗留 SERVER_PORT=${stale_server_port}，后续统一使用 Heroku 运行时 PORT"
        heroku config:unset SERVER_PORT -a "${APP_NAME}" >/dev/null
    else
        echo "未发现遗留 SERVER_PORT"
    fi

    if [ -n "${config_yaml_b64}" ]; then
        echo "检测到 SUB2API_CONFIG_YAML_B64"
    else
        echo "警告: 未检测到 SUB2API_CONFIG_YAML_B64，运行时将依赖现有数据目录内容"
    fi

    if [ "${installed_flag}" = "true" ]; then
        echo "检测到 SUB2API_INSTALLED=true"
    else
        echo "提示: SUB2API_INSTALLED 未设置为 true"
    fi

    if [ -n "${redis_conf_b64}" ]; then
        echo "检测到 SUB2API_REDIS_CONF_B64"
    else
        echo "未检测到 SUB2API_REDIS_CONF_B64，将使用镜像内默认 redis.conf"
    fi
}

podman_login_heroku() {
    echo
    echo "登录 Heroku Container Registry..."
    heroku auth:token | podman login --username=_ --password-stdin registry.heroku.com >/dev/null
}

cleanup_local_tags() {
    echo
    echo "清理本地旧镜像标签..."
    podman image rm -f "${LOCAL_IMAGE_TAG}" "${REMOTE_IMAGE_TAG}" >/dev/null 2>&1 || true
}

build_image() {
    local build_args=()

    build_args+=(--build-arg "DATE=${BUILD_DATE}")
    if [ -n "${GOPROXY:-}" ]; then
        build_args+=(--build-arg "GOPROXY=${GOPROXY}")
    fi
    if [ -n "${GOSUMDB:-}" ]; then
        build_args+=(--build-arg "GOSUMDB=${GOSUMDB}")
    fi
    if [ -n "${VERSION:-}" ]; then
        build_args+=(--build-arg "VERSION=${VERSION}")
    fi
    if [ -n "${COMMIT:-}" ]; then
        build_args+=(--build-arg "COMMIT=${COMMIT}")
    fi

    echo
    echo "构建镜像..."
    podman build \
        --pull=always \
        --no-cache \
        --platform linux/amd64 \
        --memory=8g \
        --memory-swap=10g \
        -f Dockerfile.heroku \
        "${build_args[@]}" \
        -t "${LOCAL_IMAGE_TAG}" \
        .

    echo
    echo "校验镜像内二进制..."
    podman run --rm --entrypoint /app/sub2api "${LOCAL_IMAGE_TAG}" --version
}

push_and_release() {
    echo
    echo "推送镜像到 Heroku Registry..."
    podman tag "${LOCAL_IMAGE_TAG}" "${REMOTE_IMAGE_TAG}"
    export BUILDAH_FORMAT=docker
    podman push --format=v2s2 "${REMOTE_IMAGE_TAG}"

    echo
    echo "发布镜像..."
    heroku container:release web -a "${APP_NAME}"
}

post_release_check() {
    local web_url
    local health_url
    local status_code
    local attempt

    web_url="$(heroku info -s -a "${APP_NAME}" | awk -F= '$1=="web_url"{print $2}')"
    if [ -z "${web_url}" ]; then
        echo "未读取到 web_url，跳过发布后健康检查"
        return 0
    fi

    health_url="${web_url%/}/health"

    echo
    echo "等待应用启动并检查 ${health_url} ..."
    for attempt in $(seq 1 12); do
        status_code="$(curl -sS -o /dev/null -w '%{http_code}' "${health_url}" || true)"
        if [ "${status_code}" = "200" ]; then
            echo "健康检查通过"
            return 0
        fi
        sleep 5
    done

    echo "健康检查未在预期时间内通过，请执行: heroku logs --tail -a ${APP_NAME}"
    return 1
}

echo
echo "同步运行时配置边界..."
ensure_runtime_config

podman_login_heroku
cleanup_local_tags
build_image
push_and_release
post_release_check

echo
echo "部署完成"
echo "应用地址: $(heroku info -s -a "${APP_NAME}" | awk -F= '$1=="web_url"{print $2}')"
echo "查看日志: heroku logs --tail -a ${APP_NAME}"

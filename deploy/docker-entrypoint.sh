#!/bin/sh
# deploy/docker-entrypoint.sh - Merged Version
# Features:
#   1. Fix data directory permissions (root → sub2api)
#   2. Sync config from Heroku Config Vars (base64 encoded)
#   3. Compatibility with flag-style arguments
#   4. Start Sub2API with proper user context

set -e

DATA_DIR="${DATA_DIR:-/app/data}"

# =============================================================================
# 🔐 Permission Fix: Run as root → fix perms → re-exec as sub2api
# =============================================================================
if [ "$(id -u)" = "0" ]; then
    echo "🔧 Running as root: fixing permissions on $DATA_DIR..."
    
    # Create data directory if not exists
    mkdir -p "$DATA_DIR"
    
    # Fix ownership (ignore errors for read-only files like config.yaml:ro)
    chown -R sub2api:sub2api "$DATA_DIR" 2>/dev/null || true
    
    # Also fix entrypoint script ownership if needed
    chown sub2api:sub2api "$0" 2>/dev/null || true
    
    # Re-invoke this script as sub2api user
    # All subsequent logic (config sync, app start) runs as non-root
    echo "👤 Switching to sub2api user..."
    exec su-exec sub2api "$0" "$@"
fi

# =============================================================================
# ⚙️ Argument Compatibility: Handle flag-style first argument
# =============================================================================
# If first arg looks like a flag (--xxx or -x), prepend the default binary
# This maintains compatibility with old ENTRYPOINT ["/app/sub2api"] style
if [ "${1#-}" != "$1" ]; then
    set -- /app/sub2api "$@"
fi

# =============================================================================
# 🔄 Config Sync: Pull config from Heroku Config Vars to local filesystem
# =============================================================================
sync_config_from_env() {
    # Skip if config files already exist (idempotent)
    if [ -f "$DATA_DIR/config.yaml" ] && [ -f "$DATA_DIR/.installed" ]; then
        echo "✅ Config already exists at $DATA_DIR, skipping sync"
        return 0
    fi
    
    echo "🔄 Syncing config from environment variables..."
    
    # Sync config.yaml (base64 encoded in SUB2API_CONFIG_YAML_B64)
    if [ -n "$SUB2API_CONFIG_YAML_B64" ]; then
        echo "📄 Writing config.yaml..."
        # Use temp file + atomic move to avoid partial writes
        TEMP_CONFIG="$DATA_DIR/config.yaml.tmp"
        if echo "$SUB2API_CONFIG_YAML_B64" | base64 -d > "$TEMP_CONFIG" 2>/dev/null; then
            mv "$TEMP_CONFIG" "$DATA_DIR/config.yaml"
            chmod 600 "$DATA_DIR/config.yaml"
            echo "✅ config.yaml written successfully"
        else
            echo "⚠️  Failed to decode config.yaml, skipping..."
            rm -f "$TEMP_CONFIG" 2>/dev/null || true
        fi
    else
        echo "ℹ️  SUB2API_CONFIG_YAML_B64 not set, skipping config.yaml sync"
    fi
    
    # Sync .installed lock file
    if [ "$SUB2API_INSTALLED" = "true" ]; then
        echo "🔒 Writing .installed lock..."
        touch "$DATA_DIR/.installed"
        chmod 644 "$DATA_DIR/.installed"
        echo "✅ .installed written successfully"
    else
        echo "ℹ️  SUB2API_INSTALLED not set to 'true', skipping .installed sync"
    fi
    
    # Optional: Clean sensitive env vars from process environment
    # Note: This only removes from current shell, not from parent or logs
    # unset SUB2API_CONFIG_YAML_B64 SUB2API_INSTALLED
}

# Execute config sync (before app starts, after permission fix)
sync_config_from_env

# =============================================================================
#  4. Redis 配置同步：从环境变量恢复 redis.conf
# =============================================================================
sync_redis_conf_from_env() {
    if [ -n "$SUB2API_REDIS_CONF_B64" ]; then
        echo "📦 Syncing redis.conf from environment variables..."
        TEMP_REDIS_CONF="/app/redis.conf.tmp"
        if echo "$SUB2API_REDIS_CONF_B64" | base64 -d > "$TEMP_REDIS_CONF" 2>/dev/null; then
            mv "$TEMP_REDIS_CONF" /app/redis.conf
            chmod 644 /app/redis.conf
            echo "✅ redis.conf written successfully"
        else
            echo "⚠️  Failed to decode redis.conf, using embedded default..."
            rm -f "$TEMP_REDIS_CONF" 2>/dev/null || true
        fi
    else
        echo "ℹ️  SUB2API_REDIS_CONF_B64 not set, using default /app/redis.conf"
    fi
}
sync_redis_conf_from_env

# =============================================================================
# 🚀 5. 启动内置 Redis（仅当 SKIP_BUILTIN_REDIS != true）
# =============================================================================
start_builtin_redis() {
    if [ "${SKIP_BUILTIN_REDIS}" != "true" ]; then
        echo "🔄 Starting built-in Redis..."
        mkdir -p "$DATA_DIR/redis"
        
        # 启动 Redis（后台运行）
        redis-server /app/redis.conf &
        REDIS_PID=$!
        
        # 等待 Redis 就绪（最多 10 秒）
        for i in $(seq 1 20); do
            if redis-cli -h 127.0.0.1 -p 6379 ping 2>/dev/null | grep -q PONG; then
                echo "✅ Redis ready (PID: $REDIS_PID)"
                return 0
            fi
            sleep 0.5
        done
        
        echo "⚠️  Redis failed to start, continuing anyway..."
        return 1
    else
        echo "ℹ️  SKIP_BUILTIN_REDIS=true, skipping built-in Redis"
        return 0
    fi
}

# 执行 Redis 启动（失败不中断主应用）
start_builtin_redis || true

# =============================================================================
# 🚀 Start Sub2API
# =============================================================================
echo "🚀 Starting Sub2API..."
exec "$@"

#!/bin/bash
# =============================================================================
# privacy-hardening.sh —— 宿主镜像隐私加固（对已挂载的镜像根目录执行）
#
# 用法: privacy-hardening.sh <已挂载的镜像根目录>
# 可选: BLOCK_DOMAINS="域名1 域名2" 覆盖自动探测
#
# 内容:
#   1) /etc/hosts 阻断方案厂商云管理域名——域名自动从镜像内的终端配置
#      （terminal*.conf 的 ams_address 字段）读取，仓库中不写死任何厂商信息；
#      虚机经宿主 DNS 解析，同样被阻断
#   2) 终端配置中的管理服务器地址指向 127.0.0.1（失效化）
#   3) 清空构建期遗留日志（/var/log、journal、镜像内业务日志）
# =============================================================================
M="$1"
[ -d "$M/etc" ] || { echo "用法: $0 <已挂载的镜像根目录>"; exit 1; }

echo "== 1. 探测厂商云管理域名（来自镜像自身配置）=="
DOMAINS="$BLOCK_DOMAINS"
if [ -z "$DOMAINS" ]; then
    DOMAINS=$(python3 - "$M" <<'EOF'
import json, sys, glob
root = sys.argv[1]
found = set()
for p in glob.glob(root + "/mnt/*/conf/terminal*.conf"):
    try:
        c = json.load(open(p, encoding='utf-8'))
        addr = str(c.get("ams_address", "")).strip()
        if addr and addr not in ("127.0.0.1", "localhost", "0.0.0.0"):
            found.add(addr)
    except Exception:
        pass
print(" ".join(sorted(found)))
EOF
)
fi
if [ -z "$DOMAINS" ]; then
    echo "  未从配置探测到管理域名（可能已清洗过），跳过 hosts 阻断"
else
    echo "  将阻断: $DOMAINS"
    if ! grep -q 'idv-ams-block' "$M/etc/hosts" 2>/dev/null; then
        cat >> "$M/etc/hosts" <<'EOF'

# ===== idv-ams-block: block vendor cloud endpoints =====
EOF
    fi
    for d in $DOMAINS; do
        grep -q "127.0.0.1 $d" "$M/etc/hosts" || echo "127.0.0.1 $d" >> "$M/etc/hosts"
    done
    tail -n $(( $(echo "$DOMAINS" | wc -w) + 2 )) "$M/etc/hosts"
fi

echo "== 2. 终端配置：管理服务器地址失效化 =="
python3 - "$M" <<'EOF'
import json, sys, glob
root = sys.argv[1]
for p in glob.glob(root + "/mnt/*/conf/terminal*.conf"):
    try:
        c = json.load(open(p, encoding='utf-8'))
        changed = False
        if c.get("ams_address") and c["ams_address"] != "127.0.0.1":
            c["ams_address"] = "127.0.0.1"; c["ams_port"] = 0; changed = True
        if changed:
            json.dump(c, open(p, "w", encoding='utf-8'), indent=2, ensure_ascii=False)
            print("ok", p)
    except Exception as e:
        print("skip", p, e)
EOF

echo "== 3. 清空构建期遗留日志 =="
find "$M/mnt" -name '*.log' -type f -exec : {} \; 2>/dev/null
for f in "$M"/var/log/*.log "$M"/var/log/messages* "$M"/var/log/secure* "$M"/var/log/cron* \
         "$M"/var/log/maillog* "$M"/var/log/spooler* "$M"/var/log/dmesg* "$M"/var/log/lastlog \
         "$M"/var/log/wtmp "$M"/var/log/btmp; do
    [ -f "$f" ] && : > "$f"
done
rm -rf "$M"/var/log/journal/* 2>/dev/null || true
echo "日志清理完成"

echo "== 4. 复核 =="
LEFT=0
for d in $DOMAINS; do
    HITS=$(grep -rl --binary-files=without-match "$d" "$M/etc" "$M/opt" "$M/mnt" 2>/dev/null | grep -v '/etc/hosts' | wc -l)
    LEFT=$((LEFT + HITS))
done
if [ "$LEFT" = "0" ]; then echo "无活配置残留 ✓"; else echo "警告：$LEFT 处仍引用管理域名，需人工检查"; fi
echo PRIVACY_DONE

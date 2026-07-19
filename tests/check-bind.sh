#!/usr/bin/env bash
# BIND設定とゾーンファイルの構文チェック(named-checkzone / named-checkconf)。
# 前提: bind9-utils(未導入なら `sudo apt install bind9-utils`)。
#
# named.conf.local は実機パス(/var/lib/bind、/etc/bind/minivps-update.key)を
# 参照するため、そのままでは checkconf にかけられない。router-applianceの
# lint-nftables.sh と同じ「パスをリポジトリ内へ差し替えた一時コピーを検証する」
# 方式をとり、TSIG鍵includeには検証専用のダミー鍵を一時生成して使う。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for bin in named-checkzone named-checkconf; do
  command -v "$bin" >/dev/null || {
    echo "missing: $bin (sudo apt install bind9-utils)" >&2
    exit 1
  }
done

echo "==> named-checkzone(ゾーンファイル5本)"
named-checkzone minivps.internal "$REPO_ROOT/image/var/lib/bind/db.minivps.internal"
named-checkzone 122.168.192.in-addr.arpa "$REPO_ROOT/image/var/lib/bind/db.192.168.122"
named-checkzone 201.168.192.in-addr.arpa "$REPO_ROOT/image/var/lib/bind/db.192.168.201"
named-checkzone 202.168.192.in-addr.arpa "$REPO_ROOT/image/var/lib/bind/db.192.168.202"
named-checkzone 203.168.192.in-addr.arpa "$REPO_ROOT/image/var/lib/bind/db.192.168.203"

echo "==> named-checkconf(パス差し替えコピーで検証)"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT

# 検証専用のダミーTSIG鍵(実鍵ではない。secretは "dummy-for-checkconf" のbase64)。
# 実鍵はゴールデンイメージに焼き込まず、READMEの手順で初回起動時に
# /etc/bind/minivps-update.key として配置される。
cat > "$CHECK_DIR/minivps-update.key" <<'EOF'
key "minivps-update" {
    algorithm hmac-sha256;
    secret "ZHVtbXktZm9yLWNoZWNrY29uZg==";
};
EOF

sed -e "s#/etc/bind/minivps-update.key#$CHECK_DIR/minivps-update.key#" \
    -e "s#/var/lib/bind#$REPO_ROOT/image/var/lib/bind#" \
  "$REPO_ROOT/image/etc/bind/named.conf.local" > "$CHECK_DIR/named.conf.local"
# directory はホストに /var/cache/bind が無い(bind9本体未導入)環境でも
# 検証できるよう一時ディレクトリへ差し替える。
sed -e "s#/var/cache/bind#$CHECK_DIR#" \
  "$REPO_ROOT/image/etc/bind/named.conf.options" > "$CHECK_DIR/named.conf.options"

cat > "$CHECK_DIR/named.conf" <<EOF
include "$CHECK_DIR/named.conf.options";
include "$CHECK_DIR/named.conf.local";
EOF

named-checkconf "$CHECK_DIR/named.conf"
echo "OK: BIND設定の構文チェックに通りました"

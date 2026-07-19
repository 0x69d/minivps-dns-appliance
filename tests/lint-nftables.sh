#!/usr/bin/env bash
# image/etc/nftables.conf の構文チェック。
# minivps-router-appliance版と異なり /etc/nftables.d のincludeを持たないため、
# パス差し替えなしでそのまま nft -c にかけられる。
#
# 注意: nft -c は構文チェックのみでもCAP_NET_ADMINを要求する(コンテナ/
# サンドボックス内では 'Operation not permitted' になりうる。実機または
# sudoで実行すること)。確定的な検証は実ビルドVM上で
# `sudo nft -c -f /etc/nftables.conf` を実行する。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nft -c -f "$REPO_ROOT/image/etc/nftables.conf"
echo "OK: nftables.conf の構文チェックに通りました"

#!/usr/bin/env bash
# minivps-dns-appliance ゴールデンイメージ ビルドスクリプト。
#
# ベースのUbuntu cloud imageに bind9 + nftables + 本リポジトリのゲスト内設定
# (image/etc/**, image/var/lib/bind/**)を焼き込み、libvirtの`images`
# ストレージプールへ新しいボリュームとして配置する。一時VMをcloud-initで
# カスタマイズして起動し、シャットダウン後のディスクをそのままゴールデン
# イメージとして確定する方式。
#
# ディスク/seed ISOの扱いは、mini-vps-platform自身が
# create_overlay_volume()/build_seed_iso()(mini_vps/resources.py)で
# 使っているのと同じlibvirt volume APIに揃えている:
#   - ビルド用ディスクは`images`プール内で`vol-clone`して作る。
#   - seed ISOはmini-vps-platformが使うのと同じ`vps-seeds`プールに
#     vol-create+vol-uploadで配置する。
#
# 出力: `images`プール内に <GOLDEN_IMAGE_NAME> という名前のボリュームとして配置。
# specs/dns-1.yaml の base_image をこの名前に書き換えて使う。
#
# 注意: TSIG鍵(/etc/bind/minivps-update.key)は焼き込まない。
# 初回起動時は鍵が無いため named は起動に失敗する。README「TSIG鍵の初期化」の手順で鍵を配置して回復させること。
set -euo pipefail

BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-ubuntu-26.04.img}"
GOLDEN_IMAGE_NAME="${GOLDEN_IMAGE_NAME:-minivps-dns-golden-$(date +%Y%m%d).qcow2}"
BUILD_VM_NAME="minivps-dns-build-$$"
BUILD_MEMORY_MB="${BUILD_MEMORY_MB:-1024}"
BUILD_VCPUS="${BUILD_VCPUS:-2}"
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-$HOME/.ssh/minivps_ed25519.pub}"
IMAGES_POOL="${IMAGES_POOL:-images}"
SEEDS_POOL="${SEEDS_POOL:-vps-seeds}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-600}"

# ビルド中だけ使う固定名の一時volume。成功時のみ最後にGOLDEN_IMAGE_NAMEへ
# vol-cloneで確定させる。失敗時にGOLDEN_IMAGE_NAME名の不完全な
# volumeが残ることを防ぐため。
TEMP_DISK_VOL="minivps-dns-build-disk.qcow2"
TEMP_SEED_VOL="minivps-dns-build-seed.iso"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d /var/tmp/minivps-dns-build.XXXXXX)"

cleanup() {
  # タイムアウト時はビルドVMとそのディスク/seedを意図的に残す。ゲスト内で何が
  # 失敗したかを cloud-init status / cloud-init-output.log でSSH調査するためで、
  # transientドメインを破棄すると証拠ごと消えてしまう。調査後は
  # `virsh destroy <VM名>` すれば、次回実行の冒頭掃除が残骸を回収する。
  if [ -z "${PRESERVE_BUILD_VM:-}" ]; then
    # transientドメインはpoweroffで即座にdestroy&削除されるため、
    # 保険としての destroy/undefine はベストエフォートで構わない。
    virsh destroy "$BUILD_VM_NAME" >/dev/null 2>&1 || true
    virsh undefine "$BUILD_VM_NAME" --nvram >/dev/null 2>&1 || true
    # 一時volumeは常に破棄する。成功時はGOLDEN_IMAGE_NAMEへ確定済みで不要になる。
    virsh vol-delete --pool "$IMAGES_POOL" "$TEMP_DISK_VOL" >/dev/null 2>&1 || true
    virsh vol-delete --pool "$SEEDS_POOL" "$TEMP_SEED_VOL" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> 前提チェック"
for bin in virsh cloud-localds; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done
virsh pool-info "$IMAGES_POOL" >/dev/null
virsh pool-info "$SEEDS_POOL" >/dev/null
virsh net-info default >/dev/null
[ -r "$SSH_PUBKEY_PATH" ] || { echo "pubkey not found: $SSH_PUBKEY_PATH" >&2; exit 1; }

# 前回異常終了時の残骸があれば削除。
virsh vol-delete --pool "$IMAGES_POOL" "$TEMP_DISK_VOL" >/dev/null 2>&1 || true
virsh vol-delete --pool "$SEEDS_POOL" "$TEMP_SEED_VOL" >/dev/null 2>&1 || true

echo "==> base imageをvol-cloneでビルド用ディスクに複製: $BASE_IMAGE_NAME -> $TEMP_DISK_VOL"
virsh pool-refresh "$IMAGES_POOL" >/dev/null
virsh vol-clone --pool "$IMAGES_POOL" "$BASE_IMAGE_NAME" "$TEMP_DISK_VOL"

echo "==> cloud-init user-data/meta-data を生成"
b64() { base64 -w0 "$1"; }

cat > "$WORKDIR/meta-data" <<EOF
instance-id: iid-minivps-dns-golden-build-001
local-hostname: minivps-dns-build
EOF

# bind系ファイルは defer: true でパッケージ導入後・runcmd前に書く。
# cloud-initのwrite_filesは既定でパッケージ導入前に走るため、先に書くと
#   (1) bind9導入時のnamed初回起動がTSIG鍵includeの不在で失敗しaptがエラーになる
#   (2) bindユーザ/グループが未作成でowner指定が失敗する
# の2点でビルドが壊れる。
cat > "$WORKDIR/user-data" <<EOF
#cloud-config
hostname: minivps-dns-build
users:
  - name: ubuntu
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$SSH_PUBKEY_PATH")
package_update: true
packages:
  - nftables
  - bind9
  - bind9-utils
  - bind9-dnsutils
write_files:
  - path: /etc/nftables.conf
    permissions: '0640'
    encoding: b64
    content: $(b64 "$REPO_ROOT/image/etc/nftables.conf")
  - path: /etc/bind/named.conf.options
    owner: root:bind
    permissions: '0644'
    encoding: b64
    defer: true
    content: $(b64 "$REPO_ROOT/image/etc/bind/named.conf.options")
  - path: /etc/bind/named.conf.local
    owner: root:bind
    permissions: '0644'
    encoding: b64
    defer: true
    content: $(b64 "$REPO_ROOT/image/etc/bind/named.conf.local")
  - path: /var/lib/bind/db.minivps.internal
    owner: bind:bind
    permissions: '0644'
    encoding: b64
    defer: true
    content: $(b64 "$REPO_ROOT/image/var/lib/bind/db.minivps.internal")
  - path: /var/lib/bind/db.192.168.122
    owner: bind:bind
    permissions: '0644'
    encoding: b64
    defer: true
    content: $(b64 "$REPO_ROOT/image/var/lib/bind/db.192.168.122")
  - path: /var/lib/bind/db.192.168.201
    owner: bind:bind
    permissions: '0644'
    encoding: b64
    defer: true
    content: $(b64 "$REPO_ROOT/image/var/lib/bind/db.192.168.201")
  - path: /var/lib/bind/db.192.168.202
    owner: bind:bind
    permissions: '0644'
    encoding: b64
    defer: true
    content: $(b64 "$REPO_ROOT/image/var/lib/bind/db.192.168.202")
  - path: /var/lib/bind/db.192.168.203
    owner: bind:bind
    permissions: '0644'
    encoding: b64
    defer: true
    content: $(b64 "$REPO_ROOT/image/var/lib/bind/db.192.168.203")
  - path: /root/golden-finalize.sh
    permissions: '0700'
    content: |
      #!/bin/bash
      set -euxo pipefail
      systemctl enable nftables.service named.service
      # --machine-id は比較的新しいcloud-init(24.1+)のみ対応。未対応版へのフォールバック。
      cloud-init clean --logs --machine-id || cloud-init clean --logs
      truncate -s 0 /etc/machine-id
      rm -f /root/golden-finalize.sh
      # poweroffは必ずこの関数の最後の行にする。cloud-init cleanで状態を消した後に
      # power_state: モジュール等の後続処理を動かすと、消した状態を前提にした
      # 処理が失敗しシャットダウンがスケジュールされないことがあるため、
      # power_state: ディレクティブは使わずここで直接呼ぶ。
      systemctl poweroff --no-block
runcmd:
  - /root/golden-finalize.sh
EOF

cloud-localds "$WORKDIR/seed.iso" "$WORKDIR/user-data" "$WORKDIR/meta-data"

echo "==> seed ISOをvolume APIで${SEEDS_POOL}プールへアップロード"
SEED_SIZE_BYTES=$(stat -c%s "$WORKDIR/seed.iso")
cat > "$WORKDIR/seed-vol.xml" <<EOF
<volume>
  <name>$TEMP_SEED_VOL</name>
  <capacity unit='bytes'>$SEED_SIZE_BYTES</capacity>
  <target>
    <format type='raw'/>
  </target>
</volume>
EOF
virsh vol-create "$SEEDS_POOL" "$WORKDIR/seed-vol.xml"
virsh vol-upload --pool "$SEEDS_POOL" --vol "$TEMP_SEED_VOL" --file "$WORKDIR/seed.iso" --sparse

echo "==> ビルドVMを起動(transient): $BUILD_VM_NAME"
TEMP_DISK_PATH="$(virsh vol-path --pool "$IMAGES_POOL" "$TEMP_DISK_VOL")"
TEMP_SEED_PATH="$(virsh vol-path --pool "$SEEDS_POOL" "$TEMP_SEED_VOL")"
cat > "$WORKDIR/domain.xml" <<EOF
<domain type='kvm'>
  <name>$BUILD_VM_NAME</name>
  <memory unit='KiB'>$((BUILD_MEMORY_MB * 1024))</memory>
  <vcpu>$BUILD_VCPUS</vcpu>
  <cpu mode='host-model'/>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader secure='no'/>
    <boot dev='hd'/>
  </os>
  <features><acpi/></features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='$TEMP_DISK_PATH'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$TEMP_SEED_PATH'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
    <console type='pty'><target type='serial' port='0'/></console>
  </devices>
</domain>
EOF

virsh create "$WORKDIR/domain.xml"

echo "==> cloud-init完了を待機(最大${WAIT_TIMEOUT_SEC}秒)"
# on_poweroff=destroy のtransientドメインは、poweroff発生時に「shut off」状態を
# 経由せず即座にlibvirtのドメイン一覧から消える。
elapsed=0
while virsh domstate "$BUILD_VM_NAME" >/dev/null 2>&1; do
  sleep 5
  elapsed=$((elapsed + 5))
  if [ "$elapsed" -ge "$WAIT_TIMEOUT_SEC" ]; then
    PRESERVE_BUILD_VM=1
    # 同名ホストの古いリースを拾わないよう、ビルドVMのMACでDHCPリースを引く。
    BUILD_MAC="$(virsh domiflist "$BUILD_VM_NAME" | awk '/network/ {print $5}' | head -1)"
    BUILD_IP="$(virsh net-dhcp-leases default 2>/dev/null \
      | awk -v mac="$BUILD_MAC" '$0 ~ mac {print $5}' | tail -1 | cut -d/ -f1)"
    echo "タイムアウト。調査のためビルドVMを残します:" >&2
    echo "  ssh -i ${SSH_PUBKEY_PATH%.pub} ubuntu@${BUILD_IP:-<IP不明>}" >&2
    echo "  sudo cloud-init status --long; sudo tail /var/log/cloud-init-output.log" >&2
    # cloud-initの初期段階で止まるとsshdもauthorized_keysもまだ整っておらずSSHは通らない。
    # ビルドVMを残すようになったことで、シリアルコンソールからの調査が可能になった。
    echo "SSHが繋がらない場合は virsh console $BUILD_VM_NAME でシリアルコンソールから調査する" >&2
    echo "調査後は virsh destroy $BUILD_VM_NAME で破棄してください" >&2
    exit 1
  fi
done
echo "ビルドVMの処理が完了しました(${elapsed}秒)"

echo "==> 完成したディスクを ${GOLDEN_IMAGE_NAME} として確定(vol-clone)"
virsh vol-clone --pool "$IMAGES_POOL" "$TEMP_DISK_VOL" "$GOLDEN_IMAGE_NAME"
virsh pool-refresh "$IMAGES_POOL" >/dev/null

echo "==> 完成: base_image: $GOLDEN_IMAGE_NAME としてspecから参照可能"

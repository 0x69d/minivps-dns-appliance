# minivps-dns-appliance

[mini-vps-platform](https://github.com/0x69d/mini-vps-platform)上で、内部ドメイン `minivps.internal` の権威DNSと内部向け再帰リゾルバを提供するDNSアプライアンスVM用のゴールデンイメージ・VM spec・ゲスト内設定一式。

## これは何のためのリポジトリか

mini-vps-platformのVMはこれまでIP直打ちでしか相互参照できなかった。本リポジトリは、BIND9で

- 権威ゾーン `minivps.internal`(正引き)と逆引き4ゾーン(default/seg1〜seg3)の提供
- TSIG鍵で保護された動的更新— mini-vps-platformのDNSレコード自動登録の受け口
- 内部レンジ限定の再帰リゾルバ、外部名はlibvirt dnsmasqへ転送

を担う「DNSアプライアンスVM」を、[minivps-router-appliance](https://github.com/0x69d/minivps-router-appliance)と同型の構成で、mini-vps-platformの機能だけで実現する。

`.internal` はICANNがプライベート用途に予約済みのTLDであるため採用している。外部の実在ドメインと衝突しない。

## 前提条件

- mini-vps-platformがセットアップ済み(`~/.ssh/minivps_ed25519.pub`公開鍵、`seg3`ネットワーク、`images`ストレージプール、`ubuntu-26.04.img`が`images`プールに存在すること)。
- seg1/seg2のVMからdns-1を参照する場合は、[minivps-router-appliance](https://github.com/0x69d/minivps-router-appliance)のrouter-1が稼働していること。
- ホスト側ツール: `dig`/`nsupdate`(`bind9-dnsutils`)。`tests/check-bind.sh` を回す場合はさらに `bind9-utils`。

## アーキテクチャ

```
             default (192.168.122.0/24, NAT, DHCP)
                            |
                     [管理NIC: .30]
                            |
                    +---------------+
                    |     dns-1     |
                    | (このリポジトリ)  |
                    +-------+-------+
                            |
                    [サービスNIC: .30]
                            |
                           seg3 (192.168.203.0/24)
                            |
                        [.10 (seg3側NIC)]
                    +---------------+
   seg1 ----------- |   router-1    | ----------- seg2
 (192.168.201.0/24) | (別リポジトリ)   | (192.168.202.0/24)
   [.10]            +---------------+   [.10]
```

| ネットワーク | CIDR | dns-1のIP | 用途 |
|---|---|---|---|
| default | 192.168.122.0/24 | 192.168.122.30 | 管理(SSH)・ホストからの管理クエリ |
| seg3 | 192.168.203.0/24 | 192.168.203.30 | DNSサービス提供(クライアントVMの参照先) |

dns-1はseg3への単一配置とし、seg1/seg2のVMからはrouter-1経由で192.168.203.30に到達させる([router-1側の許可ルール](#router-1側の許可ルール)参照)。このためdns-1自身のspecにもseg1/seg2への戻り経路(`static_routes: via 192.168.203.10`)を宣言している。これが無いと、クエリはclient→router-1→dns-1と届くのに、応答がデフォルトルートへ非対称に流れて、応答が返らない。

| ゾーン | 種別 | 対象 |
|---|---|---|
| minivps.internal | 正引き(権威) | VM名の名前解決 |
| 122.168.192.in-addr.arpa | 逆引き(権威) | defaultセグメント |
| 201.168.192.in-addr.arpa | 逆引き(権威) | seg1 |
| 202.168.192.in-addr.arpa | 逆引き(権威) | seg2 |
| 203.168.192.in-addr.arpa | 逆引き(権威) | seg3 |

全ゾーンの動的更新(`allow-update`)はTSIG鍵 `minivps-update` に限定している。

外部名の解決: example.com等、内部ゾーン以外は `forwarders { 192.168.203.1; }`(seg3ゲートウェイのlibvirt dnsmasq)への転送で解決する。forward先を変更する場合は `image/etc/bind/named.conf.options` の `forwarders` を書き換えて再ビルドするか、稼働中VMの `/etc/bind/named.conf.options` を編集して `sudo systemctl reload named` する。

受信制御: specの`filters`は未設定とし、router-1と同様、ゴールデンイメージに焼き込んだゲスト内nftablesのinput chainが受信制御を担う。53/tcp+udpは内部レンジから、22/tcpは管理ネット(192.168.122.0/24)からのみ許可、診断用ICMP許可、他はデフォルト拒否。

## クイックスタート

1. ゴールデンイメージをビルドする:
   ```bash
   ./build/build-golden-image.sh
   ```
   完了すると `images` プールに `minivps-dns-golden-YYYYMMDD.qcow2` という名前で配置される。出力メッセージで実際のファイル名を確認する。

2. `specs/dns-1.yaml` の `base_image` を、ビルドで得られたファイル名に書き換える。

3. VMを作成する(mini-vps-platform側で):
   ```bash
   uv run mini-vps create /path/to/minivps-dns-appliance/specs/dns-1.yaml
   ```

4. 管理アクセスを確認する:
   ```bash
   uv run mini-vps status dns-1   # ip: 192.168.122.30 が返る
   ssh -i ~/.ssh/minivps_ed25519 ubuntu@192.168.122.30
   ```

5. [TSIG鍵の初期化](#tsig鍵の初期化)を行う。これを終えるまでnamedは起動しない。

## TSIG鍵の初期化

ゴールデンイメージには意図的にTSIG鍵を焼き込んでいない。これは、イメージやgit履歴に秘密が残るのを防ぐため。`named.conf.local` は `/etc/bind/minivps-update.key` を無条件にincludeしており、鍵が配置されるまでnamedは起動に失敗する。VM初回起動後に以下を実行する:

```bash
# 1. dns-1にSSHして鍵を生成・配置する
ssh -i ~/.ssh/minivps_ed25519 ubuntu@192.168.122.30
sudo tsig-keygen -a hmac-sha256 minivps-update | sudo tee /etc/bind/minivps-update.key >/dev/null
sudo chown root:bind /etc/bind/minivps-update.key
sudo chmod 640 /etc/bind/minivps-update.key

# 2. 設定を検証してnamedを起動する
# 初回起動の失敗でstart-limitに達している場合があるため reset-failed を挟む
sudo named-checkconf
sudo systemctl reset-failed named
sudo systemctl restart named
systemctl status named --no-pager   # active (running) を確認
exit

# 3. 鍵をホスト側へ持ち出す(nsupdateとmini-vps-platformの自動登録が使う)
install -d -m 700 ~/.config/minivps
ssh -i ~/.ssh/minivps_ed25519 ubuntu@192.168.122.30 \
  sudo cat /etc/bind/minivps-update.key > ~/.config/minivps/dns-tsig.key
chmod 600 ~/.config/minivps/dns-tsig.key
```

動作確認(ホストから):

```bash
dig @192.168.122.30 dns-1.minivps.internal    # 192.168.122.30 が返る
dig @192.168.122.30 -x 192.168.203.30         # ns1.minivps.internal. が返る
dig @192.168.122.30 example.com               # forwarders経由で外部名が解決される
```

## router-1側の許可ルール

seg1/seg2のVMからdns-1(192.168.203.30)の53番へ到達させるには、router-1の許可リストであるminivps-router-applianceの `/etc/nftables.d/90-segment-allow.conf`に運用者が以下を追記する:

```
add rule inet filter forward ip saddr 192.168.201.0/24 ip daddr 192.168.203.30 udp dport 53 accept
add rule inet filter forward ip saddr 192.168.201.0/24 ip daddr 192.168.203.30 tcp dport 53 accept
add rule inet filter forward ip saddr 192.168.202.0/24 ip daddr 192.168.203.30 udp dport 53 accept
add rule inet filter forward ip saddr 192.168.202.0/24 ip daddr 192.168.203.30 tcp dport 53 accept
```

追記後は必ずメインファイル経由でreloadする:

```bash
sudo systemctl reload nftables
```

## クライアントVM側の設定

dns-1を参照するVMは静的IP + `nameservers`指定を必要とする。DHCP割当VMのリゾルバ切替はスコープ外で、DHCPのNICはlibvirt dnsmasqをリゾルバとして受け取る。mini-vps-platformの `nameservers`/`search`/`static_routes` を使う:

```yaml
# seg1側のクライアントVMの例
name: web-1
memory: 1024
vcpus: 2
base_image: ubuntu-26.04.img
disk: 10
networks:
  - name: seg1
    address: 192.168.201.50/24
    gateway: 192.168.201.1
    nameservers:
      - 192.168.203.30
    search:
      - minivps.internal
static_routes:
  - destination: 192.168.203.0/24
    via: 192.168.201.10   # router-1 の seg1 側IP
```

クライアントVM内での確認:

```bash
resolvectl status                        # 該当リンクのDNS Serversに192.168.203.30が出る
resolvectl query dns-1.minivps.internal  # 正引きが返る
ping dns-1   # searchドメインにより短縮名でも解決される
```

## レコードの手動追加(nsupdate)

router-1を題材に、ホストからTSIG鍵でAとPTRをセットで登録する例:

```bash
nsupdate -k ~/.config/minivps/dns-tsig.key <<'EOF'
server 192.168.122.30
update add router-1.minivps.internal. 300 A 192.168.122.10
send
update add 10.122.168.192.in-addr.arpa. 300 PTR router-1.minivps.internal.
send
EOF
```

A(minivps.internal)とPTR(in-addr.arpa)は別ゾーンのため`send`を分ける(動的更新は1メッセージ=1ゾーン)。削除は `update delete router-1.minivps.internal. A` のようにレコード型を指定して行う。

## tests

- `tests/lint-nftables.sh` — nftables.confの構文チェック。
- `tests/check-bind.sh` — ゾーンファイル5本の`named-checkzone`と、パス差し替えコピーによる`named-checkconf`(要`bind9-utils`)。

## トラブルシューティング

- ビルドがタイムアウトした場合: `virsh console <ビルドVM名>` でシリアルコンソールに接続して調査する。ビルド用ドメインはtransientで、シャットダウンと同時に消滅する点に注意。
- namedが起動しない(作成直後): TSIG鍵が未配置なら仕様。[TSIG鍵の初期化](#tsig鍵の初期化)を実施する。
- 動的更新対象ゾーンの手動編集: 稼働中のゾーンファイルを直接編集してはならない。journal(`.jnl`)と矛盾し、変更が失われるかゾーンのロードに失敗する。必ずfreezeしてから編集する:
  ```bash
  sudo rndc freeze minivps.internal
  sudo vi /var/lib/bind/db.minivps.internal   # serialを上げるのを忘れない
  sudo rndc thaw minivps.internal
  ```
- `mini-vps status`が管理IP以外を返す場合: `specs/dns-1.yaml`の`networks`の並び順(`default`が先頭かつ静的IPになっているか)を確認する。
- DHCPレンジとの重複: 192.168.203.30/192.168.122.30はいずれもlibvirt DHCPレンジ(.2〜.254)内にある。dns-1は常時起動の運用を前提とし、長期停止させる場合は同アドレスのDHCP払い出しと衝突しうる点に注意する。

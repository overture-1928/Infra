# OpenWrt Provider VLAN 자동화

현재 단일 노드 구성은 OpenWrt가 관리망 `192.0.2.0/24`와 OpenStack Provider VLAN 10을
라우팅한다. OpenStack을 먼저 배포하면 `br-ex`가 `mgmt0.10`을 점유해 안전한 임시 주소 검사를
할 수 없으므로, Ubuntu 호스트 준비와 재부팅을 마친 뒤 OpenStack 배포 전에 이 절차를 실행한다.
실제 라우터 주소·포트·SSH 키 경로를 기록할 파일과 백업 위치는
[로컬 전용 설정, 인증정보와 운영 상태](local-secrets-and-state.md)를 따른다.

자동화가 만드는 경로는 다음과 같다.

| 구간 | OpenWrt 구성 | 정책 |
| --- | --- | --- |
| 관리망 | 기존 `lan`, native/untagged VLAN 1, `192.0.2.1/24` | 기존 SSH·DHCP·DNS 유지 |
| Provider망 | `os_provider`, tagged VLAN 10, `198.51.100.1/24` | DHCP·RA 끔, router input 기본 차단 |
| LAN → Provider | `lan_to_os_provider` | 관리자 PC에서 Floating IP 접근 허용 |
| Provider → WAN | `os_provider_to_wan` | VM outbound 허용, 기존 WAN masquerade 사용 |
| Provider → LAN | `os_provider_to_lan_reject` | 관리망 접근 차단 |

OpenStack 설정의 DNS가 `192.0.2.1`이므로 Provider zone에서 라우터 자신의 TCP/UDP 53과
검사용 ICMP echo만 예외로 허용한다. 기존 LAN/WAN section을 통째로 교체하지 않고 이름이
`os_*`인 network·DHCP·firewall section을 반복 관리한다. DSA VLAN filtering을 켤 때 기존
`network.lan.device`만 발견한 `br-lan`에서 management VLAN device인 `br-lan.1`로 바꾼다.

## 사전 조건

이 구현은 DSA와 `fw4`를 사용하는 OpenWrt, root 공개키 SSH, `ubus`, `uci`, `jsonfilter`,
`ip`, `sysupgrade`, `tar`, `base64`, SCP를 전제로 한다. 비밀번호 SSH와 host key 검사 해제는
지원하지 않는다. OpenWrt가 연결된 포트의 지문을 장비 화면이나 로컬 콘솔에서 확인한 뒤
관리 PC의 `known_hosts`에 등록한다.

첫 DSA VLAN 변경은 LAN 브리지 전체를 다시 불러오므로 로컬 또는 serial console과 전원 접근을
확보한다. 인벤토리의 `physical_console_available: true`는 이 복구 경로를 실제로 확보한 뒤에만
설정한다.

OpenWrt와 `cloud01` 사이에 관리형 스위치가 있으면 그 스위치도 별도로 구성해야 한다.
OpenWrt uplink와 서버 포트에서 관리망은 untagged/PVID 1, VLAN 10은 tagged여야 한다. 이
저장소는 외부 스위치의 설정 API를 알 수 없으므로 해당 변경은 수행하지 않는다.

## 장비 정보 수집과 계획

로컬 인벤토리를 만든다. 이 파일은 Git에서 제외된다.

```bash
umask 077
test -e inventory/openwrt-router.local.yml || \
  cp inventory/openwrt-router.example.yml inventory/openwrt-router.local.yml
chmod 0600 inventory/openwrt-router.local.yml
./scripts/cluster.sh openwrt-discover
```

`openwrt-discover`는 라우터를 변경하지 않는다. `.cache/openwrt/discovery.json`에서 다음 값을
확인해 로컬 인벤토리의 모든 `REPLACE` 값을 채운다.

- `board_name`, OpenWrt release target과 version
- DSA bridge section, 실제 bridge name과 전체 ports
- 기존 `lan`과 `wan` firewall zone, WAN masquerade
- `/etc/config/network`, `firewall`, `dhcp`의 SHA-256

`dsa_bridge.management_ports`에는 현재 bridge의 모든 LAN 포트를 넣는다. OpenStack 서버가 직접
연결된 포트나 관리형 스위치 uplink만 `provider_tagged_ports`에도 넣는다. 나중에 노드를
추가하면 해당 노드로 VLAN 10을 전달하는 포트 또는 같은 스위치 trunk를 포함한다.
최초 설치에서는 `deployed_nodes: []`와 `cloud01`의 probe 주소를 유지한다.
발견한 UCI section이 `@device[0]`처럼 `@`로 시작하면 YAML 값의 따옴표를 유지한다.

복구 경로를 확인하고 `enabled: true`, `physical_console_available: true`로 바꾼 뒤 계획을
만든다.

```bash
./scripts/cluster.sh openwrt-plan
cat .cache/openwrt/uci.batch
python3 -m json.tool .cache/openwrt/plan.json | less
```

렌더러는 라우터의 모델·릴리스·포트, OpenStack CIDR·VLAN·Floating IP 풀, 활성 노드별 probe
주소, WAN masquerade와 현재 설정 해시를 서로 대조한다. 기존의 이름 없는 VLAN 1 또는 10
section과 충돌하거나 수집 이후 설정이 달라지면 적용 계획을 만들지 않는다.

## Guarded 적용

`openwrt-plan`이 출력한 apply와 confirm 값을 그대로 따옴표로 묶어 설정한다. 두 값은 장비,
포트, VLAN, 입력 파일과 설정 해시에 묶여 있어 재수집 결과가 바뀌면 더 이상 유효하지 않다.

```bash
export OPENWRT_APPLY_CONFIRM='APPLY-OPENWRT:<plan이 출력한 실제 값>'
export OPENWRT_CONFIRM='CONFIRM-OPENWRT:<plan이 출력한 실제 값>'
./scripts/cluster.sh openwrt-apply
```

`openwrt-apply`는 다음 순서를 한 transaction으로 실행한다.

1. 같은 저장소의 동시 실행을 잠그고 고유한 시도 ID를 만든 뒤, 라우터를 다시 수집해 동일한
   계획과 확인값인지 검사
2. OpenWrt `sysupgrade`와 `/etc/config` 백업을 라우터와 `state/openwrt/`에 mode `0600`으로 저장
3. 재부팅 후에도 동작하는 300초 rollback guard를 먼저 시작
4. UCI 후보를 stage하고 `fw4 check`가 성공한 뒤에만 commit과 reload
5. SSH, 원하는 UCI 값, LAN interface와 관리 노드 통신 확인
6. 기존 배포 노드는 `mgmt0.10`의 `br-ex` 편입을 읽기 전용으로 확인하고, 신규 노드는 고유
   임시 주소로 `198.51.100.1` ping
7. 모든 활성 노드의 검사가 성공한 경우에만 guard 해제

임시 주소는 항상 제거한다. probe 대상으로 선택한 노드에 `br-ex`가 이미 존재하거나
`mgmt0.10`이 bridge에 편입된 상태에서는 주소를 추가하지 않고 중단한다.

나중에 `cloud02`와 `cloud03`을 추가할 때는 OpenStack에 이미 편입된 `cloud01`을
`deployed_nodes`에 적고 `probe_addresses`에는 아직 `br-ex`가 없는 새 노드만 둔다. 두 목록의
합은 활성 OpenStack 노드 전체와 정확히 같아야 하며 새 probe 노드가 최소 한 대 있어야 한다.
이 상태에서 새 포트의 `provider_tagged_ports`를 함께 검토해 `openwrt-apply`를 실행하면 기존
노드에는 임시 주소를 추가하지 않고 `mgmt0.10`이 실제 `br-ex` 포트인지 확인하며, 새 노드는
tagged gateway 경로를 능동 검사한다. 새 노드가 하나도 없는 운영 중 클라우드에서는 재적용
대신 `openwrt-status`를 사용한다.

적용 중 검사가 실패하면 guard를 해제하지 않는다. 라우터가 SSH로 접속되는 동안 즉시 되돌릴
때는 `openwrt-plan`이 출력한 rollback 값을 사용한다.

백업이나 guard 시작 전 단계에서 실패한 시도는 그 시도 ID와 라우터 전역 잠금의 소유자가
정확히 일치하고 `ARMED`가 없을 때만 자동 정리된다. guard가 시작된 뒤의 실패는 이 정리 경로가
건드리지 않으며 rollback 또는 confirm만 transaction을 끝낼 수 있다. rollback은 저장한 설정을
복원한 뒤 network·firewall·dnsmasq와 존재하는 odhcpd 재시작이 모두 성공해야만 guard와 전역
잠금을 해제한다.

guard가 armed 상태인 동안에는 기존 `.cache/openwrt/plan.json`과 확인값을 보존해야 한다.
discovery는 현재 transaction을 표시하고 새 `openwrt-plan`과 `openwrt-apply`는 기존 plan을
덮어쓰지 않고 거부한다.

```bash
export OPENWRT_ROLLBACK_CONFIRM='ROLLBACK-OPENWRT:<plan이 출력한 실제 값>'
./scripts/cluster.sh openwrt-rollback
```

SSH가 끊겼다면 전원을 끄지 않고 rollback 기한까지 기다린다. guard는 재부팅으로 장비 시계가
과거로 돌아가도 재부팅 후 대기 시간을 설정된 rollback 시간 이내로 제한한다. 적용 transaction은
라우터 전역 잠금으로 한 번에 하나만 실행되며 stage·검증·commit과 rollback은 같은 finalize
잠금을 사용한다. guard는 `/etc/config` 백업을 복원하고 network, firewall, dnsmasq, odhcpd를
다시 시작한다. 적용이 성공한 뒤에는 다음 명령으로 마지막 계획과 현재 UCI 값을 다시 확인할 수 있다.

```bash
./scripts/cluster.sh openwrt-status
```

## 주소의 의미

`198.51.100.0/24`는 공개 문서의 Provider망 예시다. 실제 구성에서는 로컬 인벤토리의 사설
Provider망을 사용한다. 이 구성으로 LAN이나 관리 VPN에서 Floating IP에
접근하고 VM이 WAN으로 나갈 수 있지만, 인터넷에서 Floating IP로 직접 들어올 수는 없다.
외부 inbound가 필요하면 OpenWrt에 제한된 DNAT/port-forward를 추가하거나 ISP가 라우팅하는
공인 prefix를 Provider망에 배정하는 별도 설계가 필요하다.

## 공식 자료

- [OpenWrt DSA VLAN tagging](https://openwrt.org/docs/guide-user/network/dsa/dsa-mini-tutorial/dsa-common-config/4-multiple-networks-using-vlan-tagging)
- [OpenWrt DSA VLAN security](https://openwrt.org/docs/guide-user/network/dsa/dsa-mini-tutorial/dsa-common-config/6-security-considerations_for_vlans)
- [OpenWrt firewall configuration](https://openwrt.org/docs/guide-user/firewall/firewall_configuration)
- [OpenWrt DHCP configuration](https://openwrt.org/docs/guide-user/base-system/dhcp_configuration)
- [OpenWrt UCI](https://openwrt.org/docs/techref/uci)
- [OpenWrt backup and restore](https://openwrt.org/docs/guide-user/troubleshooting/backup_restore)

# OpenStack 망분리 설계

이 문서의 `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`는 공개 저장소를 위한
RFC 5737 예시다. 실제 주소는 Git에서 제외되는 로컬 인벤토리에 기록한다.

이 저장소는 한 물리 노드에서 시작해 세 노드로 확장한다. 처음부터 모든 트래픽에 별도
물리 NIC를 요구하지 않는다. VLAN으로 보안과 브로드캐스트 영역을 먼저 나누고, 세 노드와
Ceph를 도입할 때 저장 트래픽을 별도 NIC 또는 bond로 옮긴다.

## 현재 한 노드 구성

현재 자동화가 만드는 망은 다음과 같다.

| 구분 | 물리·논리 인터페이스 | 주소 | 현재 용도 |
| --- | --- | --- | --- |
| 관리·API | `mgmt0`, untagged/native | `192.0.2.0/24` | Ubuntu, SSH, Kolla API, Skyline, OVN tunnel |
| OpenStack API VIP | `mgmt0` | `192.0.2.10` | HAProxy·Keepalived VIP와 management Kubernetes HA endpoint |
| Provider 외부망 | `mgmt0.10`, tagged VLAN 10 | `198.51.100.0/24` | Floating IP와 north-south 트래픽 |
| Tenant 논리망 | OVN Geneve overlay | `203.0.113.0/24` | Kubernetes VM 고정 IP와 Neutron router |

`203.0.113.0/24`는 물리 스위치에 만드는 VLAN이 아니다. OVN이 물리 underlay 위에 만드는
프로젝트 논리망이다.

한 노드에서는 Ceph가 꺼져 있으므로 별도 저장망이 필요 없다. 이 구성은 VLAN 10을 처리할
관리형 스위치와 `198.51.100.1` 게이트웨이·라우팅을 제공할 라우터 또는 방화벽이 있어야
동작한다. 일반 스위치만 연결하고 `mgmt0.10`을 만들면 외부 게이트웨이에 도달할 수 없다.
현재 OpenWrt를 라우터로 쓸 때는 [OpenWrt Provider VLAN 자동화](openwrt-router.md)가 기존
LAN을 native VLAN 1로 유지하면서 VLAN 10 gateway와 방화벽 경로를 만든다.

노드가 연결된 스위치 포트는 다음 조건을 만족해야 한다.

- 관리망 `192.0.2.0/24`는 untagged/native VLAN
- VLAN 10은 tagged 허용
- `192.0.2.10`, provider router `198.51.100.2`와 Floating IP `198.51.100.50-99`는 DHCP 범위에서 제외
- `mgmt0.10`에는 호스트 IP와 기본 경로를 설정하지 않음
- 기본 경로는 관리망의 `192.0.2.1` 하나만 사용

Terraform은 외부 Neutron 네트워크를 `flat/physnet1`로 만든다. Linux의 `mgmt0.10`이 이미
VLAN 10 태그를 제거한 프레임을 Kolla의 `br-ex`에 전달하기 때문이다. 이 구조에서 Neutron
네트워크를 다시 `vlan`, segmentation ID 10으로 만들면 이중 태깅이 될 수 있다.

## 세 노드 목표 구성

두 번째 NIC를 추가할 수 있다면 다음 구성을 기본 목표로 한다.

| 구분 | VLAN·서브넷 예시 | 노드 주소 | Gateway | 물리 경로 |
| --- | --- | --- | --- | --- |
| 관리·API | native, `192.0.2.0/24` | `.2`, `.4`, `.5`; VIP `.10` | `.1` | NIC 1 |
| Provider 외부망 | VLAN 10, `198.51.100.0/24` | 호스트 IP 없음 | `.1` | NIC 1 trunk |
| OVN tunnel | VLAN 20, `192.168.20.0/24` | `.2`, `.4`, `.5` | 없음 | NIC 1 trunk |
| Ceph public/client | VLAN 30, `192.168.30.0/24` | `.2`, `.4`, `.5` | 없음 | NIC 2 또는 storage bond |
| Ceph cluster | VLAN 31, `192.168.31.0/24` | `.2`, `.4`, `.5` | 없음 | 별도 고속 경로가 있을 때만 |
| Tenant overlay | `203.0.113.0/24` | VM 주소 | Neutron router | 물리 VLAN 없음 |

NIC가 한 개뿐이면 VLAN 10·20·30을 같은 trunk에 실을 수 있다. L2와 접근 정책은 분리되지만
대역폭, NIC 장애와 스위치 포트 장애는 공유한다. NVMe Ceph 복구 트래픽과 VM 트래픽이 같은
1GbE 링크를 쓰면 성능이 크게 떨어질 수 있으므로 세 노드 전환 시 두 번째 NIC를 Ceph
public/client망에 우선 배정한다.

Ceph `cluster_network`는 필수가 아니다. 같은 단일 NIC에 VLAN 31만 추가해도 대역폭이나 장애
경로가 달라지지 않는다. 우선 VLAN 30의 public network 하나를 사용하고, 별도 10/25GbE NIC나
redundant storage bond가 준비되고 복구 트래픽 병목이 확인됐을 때만 cluster network를 추가한다.

OpenStack API와 Skyline(`http://192.0.2.10:9999`)은 관리망에서만 접근하고 인터넷에 직접 공개하지 않는다. 외부에서
관리할 때는 VPN 또는 bastion을 사용한다. 공개 API가 실제로 필요할 때만 Provider/Floating IP
망과 별개의 API VLAN, external VIP와 TLS를 추가한다.

## 접근 정책

라우터·방화벽 또는 L3 스위치 ACL을 우선 사용한다. Kolla 호스트에서 UFW나 iptables 규칙을
즉흥적으로 다시 적용하면 Docker·OVN 규칙과 충돌할 수 있다.

| 출발지 | 목적지 | 허용 범위 |
| --- | --- | --- |
| 관리자 PC 또는 관리 VPN | 관리망 | SSH, HTTPS/API, 필요한 경우 Kubernetes `6443` |
| OpenStack 노드 | 관리망의 다른 노드 | Kolla control-plane 서비스와 클러스터 통신 |
| OpenStack 노드 | OVN tunnel망 | 노드 간 Geneve UDP `6081` |
| OpenStack·Ceph 노드 | Ceph public망 | monitor `3300/6789`, OSD `6800-7568` |
| Ceph OSD 노드 | 선택 Ceph cluster망 | OSD `6800-7568` |
| Provider 외부망 | 관리·tunnel·Ceph망 | 기본 차단 |

Tenant VM의 ingress는 Neutron security group에서 별도로 제한한다. Terraform의 `admin_cidr`는
가능하면 전체 관리 `/24` 대신 관리자 PC `/32` 또는 관리 VPN CIDR로 좁힌다. Tenant가 쓰는
DNS도 해당 망에서 실제로 라우팅 가능한 주소를 지정한다.

## MTU 원칙

처음에는 NIC, VLAN, 스위치, 라우터를 모두 MTU 1500으로 유지한다. OVN Geneve와 Kubernetes
CNI가 중첩되면 VM 안의 CNI MTU는 더 작아야 하므로 큰 ping과 실제 Pod 통신으로 PMTU를
검증한다. MTU 9000은 모든 노드 NIC, 스위치 trunk, bond, VLAN subinterface와 라우터가 전
구간에서 지원할 때만 한 번에 적용한다.

## 현재 자동화 경계

`prepare-openstack-host.yml`은 `mgmt0`과 IP가 없는 `mgmt0.10`을 만든다. OpenWrt 자동화는
라우터에서 VLAN 10과 gateway를 구성하고 OpenStack 배포 전에 각 활성 노드에서 tagged 경로를
검사한다. 중간의 외부 관리형 스위치 trunk는 장비별로 별도 구성해야 한다. Kolla는
`network_interface`, `api_interface`, `tunnel_interface`를 모두 `mgmt0`으로 사용한다. 따라서
VLAN 20이나 VLAN 30을 스위치에 먼저 추가하는 것만으로 tunnel·Ceph 트래픽이 이동하지 않는다.

별도 tunnel·Ceph망을 활성화할 때는 다음 항목을 한 변경으로 함께 적용해야 한다.

1. 세 노드의 Netplan VLAN 또는 전용 NIC 주소
2. Kolla per-host `tunnel_interface`와 storage 관련 인터페이스
3. `cluster.ceph.public_network`와 각 노드의 `ceph_address`
4. 노드 간 주소·MTU·Geneve·Ceph port 사전 검사
5. 기존 클라우드라면 Kolla reconfigure와 VM overlay·Ceph 복구 시험

배포 후 관리 CIDR이나 API VIP를 바꾸면 OpenStack endpoint, HAProxy·Keepalived, TLS SAN,
Terraform의 `management_api_address`와 Kubernetes kubeconfig까지 함께 바뀐다. 관리망과 VIP는
최초 배포 전에 확정하고 이후에는 별도 유지보수 변경으로 취급한다.

## 공식 근거

- [Kolla-Ansible 2026.2 production architecture](https://docs.openstack.org/kolla-ansible/2026.2/admin/production-architecture-guide.html)
- [Kolla-Ansible 2026.2 quick start](https://docs.openstack.org/kolla-ansible/2026.2/user/quickstart.html)
- [Kolla-Ansible 2026.2 Neutron networking](https://docs.openstack.org/kolla-ansible/2026.2/reference/networking/neutron.html)
- [Ceph network configuration reference](https://docs.ceph.com/en/latest/rados/configuration/network-config-ref/)
- [Neutron MTU configuration](https://docs.openstack.org/neutron/latest/configuration/neutron.html)

# Ubuntu Server에서 시작하는 OpenStack 클러스터

이 저장소는 물리 서버 `cloud01` 한 대에 Ubuntu Server 24.04와 Kolla-Ansible OpenStack을
설치하고, 나중에 `cloud02`, `cloud03`을 함께 추가해 3노드 제어·네트워크·컴퓨트 클러스터로
확장하는 자동화를 제공한다. OpenStack 위의 Kubernetes 인프라는 Terraform으로 만들고
Kubespray로 설치한다.

```text
Ubuntu Server 설치
  -> Ansible 호스트 준비
  -> Ansible OpenWrt Provider VLAN 준비
  -> Kolla-Ansible OpenStack
  -> Terraform OpenStack 자원과 Kubernetes VM
  -> Kubespray Kubernetes
```

현재 저장소의 기본 토폴로지는 `cloud01`만 활성화되어 있다. 실제 장비에는 적용하지 않았으며,
Ubuntu 자동 설치, OpenStack 스토리지 초기화, Terraform 적용과 Ceph OSD 생성에는 각각 별도의
검토와 확인 절차가 있다.

## 토폴로지의 기준 파일

물리 노드, 주소, NIC, 역할과 스토리지 모드는
[`inventory/openstack-cluster.yml`](inventory/openstack-cluster.yml)에서 관리한다. 실제 환경에서는
Git에서 제외되는 로컬 파일을 만들어 사용한다. 로컬 파일별 입력 항목, 권한과 백업 대상은
[로컬 전용 설정, 인증정보와 운영 상태](docs/local-secrets-and-state.md)에 정리되어 있다.

```bash
umask 077
test -e inventory/openstack-cluster.local.yml || \
  cp inventory/openstack-cluster.yml inventory/openstack-cluster.local.yml
test -e inventory/openstack-plan.local.yml || \
  cp inventory/openstack-plan.yml inventory/openstack-plan.local.yml
chmod 0600 \
  inventory/openstack-cluster.local.yml \
  inventory/openstack-plan.local.yml
```

추적되는 두 YAML은 공개 저장소용 예시다. 실제 MAC 주소, 디스크 시리얼과 환경별 주소는
Git에서 제외되는 `.local.yml` 파일에만 기록한다. 렌더러와 스토리지·OpenWrt 스크립트는 로컬
파일이 있으면 이를 우선 사용한다. `cloud02`와 `cloud03`을 활성화하기 전에 각 장비의 MAC
주소와 OS 디스크 시리얼을 실제 값으로 바꿔야 한다. 다음 조건을 만족하지 않으면 인벤토리를
생성하지 않는다.

추적되는 관리망 `192.0.2.0/24`, Provider망 `198.51.100.0/24`, tenant망
`203.0.113.0/24`는 RFC 5737 문서 전용 대역이다. 실제 배포 전에 두 로컬 인벤토리와
`terraform.tfvars`에서 사용 가능한 사설망 주소로 바꾼다.

- 활성 노드 수는 한 대 또는 세 대 이상이어야 한다.
- 컨트롤러는 한 대이거나, 3 이상의 홀수여야 한다.
- 3노드 이상에서는 control과 network 역할이 각각 최소 세 대에 있어야 한다.
- 관리 주소와 MAC 주소는 중복될 수 없다.
- LVM 모드의 storage 역할은 `cloud01`에만 둘 수 있다.
- `cloud01`은 설치 때부터 확장 후까지 같은 Kolla 인벤토리 이름을 유지한다.

[`scripts/cluster.sh`](scripts/cluster.sh)가 이 파일을 검증한 뒤 Ansible 인벤토리, Kolla
인벤토리와 Kolla 전역 설정을 생성한다.

```bash
./scripts/cluster.sh validate
./scripts/cluster.sh setup
./scripts/cluster.sh render
```

생성물은 `.cache/cluster/`, `kolla/inventory/multinode.local`과 `kolla/generated/`에 저장되며
Git에 포함되지 않는다.

`setup`은 저장소 안에 고정 버전 Kolla-Ansible과 체크섬으로 검증한 Terraform CLI를 설치한다.
`prepare-hosts`와 `verify-hosts`는 일반 `operator` 사용자로 실행한다. 두 Ansible playbook이
원격 호스트에서 자체적으로 `become: true`를 사용하므로 wrapper를 `sudo`로 실행하지 않는다.
Ubuntu 자동 설치는 공개키 전용 SSH와 함께 이 작업에 필요한
`/etc/sudoers.d/90-operator-ansible`을 만들고 `visudo`로 검사한다.
반대로 `deploy-openstack`, `expand-openstack`, `platform-apply`와
`platform-reconfigure`의 Kolla 작업은 로컬에서 root로 실행된다. SSH 연결 노드가 있다면
검토한 지문을 `/root/.ssh/known_hosts`에 미리 등록하거나
`ANSIBLE_SSH_COMMON_ARGS='-o UserKnownHostsFile=/home/operator/.ssh/known_hosts'`처럼 검토한
파일을 명시하고 해당 환경 변수를 `sudo --preserve-env`로 전달해야 한다. host key 검사를
비활성화하지 않는다.

## 단일 노드 구성

```text
cloud01
├─ control / network / compute / monitoring / storage
├─ OpenStack API VIP 192.0.2.10
├─ Cinder LVM fast + standard
└─ OpenStack VM k8s-01
   └─ 단일 노드 Kubernetes
```

한 물리 서버에서 모든 서비스가 실행되므로 호스트 장애를 견디지 못한다. OpenStack API VIP와
Kubernetes API VIP는 확장 후에도 같은 주소를 쓰기 위해 처음부터 예약한다.

호스트 준비 자동화는 최소 8 CPU 스레드와 32GB RAM을 요구한다. 한 서버에서 OpenStack과
Kubernetes VM을 함께 운영하려면 64GB 이상을 권장한다.

## 3노드 확장 구성

`cloud02`와 `cloud03`을 함께 활성화하면 다음 역할을 렌더링한다.

| 역할 | 물리 노드 |
| --- | --- |
| control | `cloud01`, `cloud02`, `cloud03` |
| network | `cloud01`, `cloud02`, `cloud03` |
| compute | `cloud01`, `cloud02`, `cloud03` |
| monitoring | `cloud01` |
| storage, LVM 단계 | `cloud01` |

세 컨트롤러에 MariaDB, RabbitMQ와 API 서비스가 배치되고 Nova가 세 컴퓨트 노드를 하나의
자원 풀로 관리한다. `scripts/cluster.sh expand-openstack`이 데이터베이스 백업, Kolla 사실
수집, 호스트 bootstrap, deploy, 설정 검증과 서비스 검사를 순서대로 실행한다.

LVM을 사용하는 동안 Cinder 볼륨과 기본 Glance 파일 데이터는 `cloud01`에 남는다. 이 단계는
제어·네트워크·컴퓨트 계층을 확장하지만 데이터 HA를 제공하지 않는다. 완전한 스토리지 HA는
세 노드 이상의 전용 OSD로 Ceph를 먼저 구성하고, 기존 데이터를 검증하며 옮긴 다음 Kolla를
전환해야 한다. Ceph 구축과 LVM 데이터 이전은 OpenStack 확장과 분리된 작업이다.
Ceph의 같은 디스크 종류는 동일 모델이 아니라 `hdd`, `ssd`, `nvme` 장치 class를 뜻한다.
OpenStack 풀에 선택한 class는 세 OSD 호스트에 모두 있어야 하며, 자동화는 그 class만 쓰는
host failure-domain CRUSH rule에 `images`, `volumes`, `vms` 풀을 고정한다.

구체적인 노드 추가 절차는 [3노드 확장 문서](docs/three-node-expansion.md), 자동화가 실행하는
범위와 확인 문자열은 [자동화 안전 경계](docs/automation-boundaries.md)에 있다.

## 단계별 플랫폼 목표

현재 한 노드 단계의 범위는 Nova·Neutron·Glance·Cinder를 포함한 핵심 OpenStack,
Skyline/OpenStack API, 그리고 최초 Kubespray management/hosting cluster다. 이 Kubernetes
클러스터는 앞으로 클러스터 생명주기 controller와 플랫폼 API를 실행할 부트스트랩
클러스터이며, 영구적인 유일 workload cluster로 보지 않는다.

Neutron은 최초 배포부터 OVN을 사용한다. 한 노드에서는 Octavia와 Magnum 같은 managed
service를 비활성화해 두고, 3노드와 Ceph 검증 후 Octavia OVN provider와 Magnum/CAPI를
별도 변경으로 활성화한다. 이 선택은 운영 중 OVS에서 OVN으로 옮기는 작업과 Amphora
이미지·인증서 준비를 피한다.

3노드 OpenStack과 Ceph 데이터 HA 및 복구 시험이 끝나면 다음 계층을 별도 변경으로 추가한다.

| 사용자 기능 | 목표 구현 |
| --- | --- |
| 인프라 UI·API | Skyline과 OpenStack API를 제공하고, 이후 자체 포털이 동일 API를 호출 |
| ECS와 유사한 컨테이너 서비스 | 포털의 container-runtime API가 Kubernetes workload를 조정 |
| EKS와 유사한 Kubernetes 서비스 | Magnum API, Kolla Magnum 이미지의 VEXXHOST `magnum-cluster-api` driver와 CAPO로 OpenStack VM 기반 클러스터 관리 |
| Hosted Control Plane | 필요할 때 k0smotron v2.3.0을 management/hosting cluster에 설치 |

이 저장소가 고정한 OpenStack/Kolla-Ansible 2026.2에서는 Kolla의 Zun·Kuryr 배포 지원이
2026.1부터 제거되었으므로 `enable_zun`이나 `enable_kuryr`를 추가하지 않는다. ECS와 유사한
기능은 Kubernetes 기반 runtime API를 자체 포털 뒤에 두는 방향으로 설계한다. Zun이 반드시
필요하면 2025.2 legacy 프로필의 수명주기와 보안 부담을 별도 결정해야 하며, 현재 구성에
혼합하지 않는다.

Magnum의 Heat driver도 2026.2에서 제거되었다. 현재 Kolla 2026.2 Magnum 이미지에는
VEXXHOST의 `magnum-cluster-api` driver가 포함되어 있으며 이 저장소의 자동화도 해당
`k8s_cluster_api` 경로를 활성 상태로 검증한다. driver를 별도로 설치하는 구조가 아니다.
Hosted Control Plane은 저장소에 고정된 k0smotron v2.3.0을 사용한다.
k0smotron은 OpenStack, Magnum, CAPI 또는 CAPO의 내장 기능이 아닌 별도 control-plane
provider다. 버전 근거는
[Kolla-Ansible 2026.1 릴리스 노트](https://docs.openstack.org/releasenotes/kolla-ansible/2026.1.html),
[Magnum 2026.1 역할 문서](https://docs.openstack.org/openstack-ansible-os_magnum/2026.1/),
[VEXXHOST Magnum Cluster API driver](https://vexxhost.github.io/magnum-cluster-api/),
[Magnum workload image](https://vexxhost.github.io/magnum-cluster-api/user/images/),
[CAPO Hosted Control Plane 가이드](https://cluster-api-openstack.sigs.k8s.io/topics/hosted-control-plane),
[k0smotron v2.3.0](https://docs.k0smotron.io/v2.3.0/install/)에서 확인한다.

3노드와 Ceph 전환이 끝난 뒤 `cluster.platform.magnum_capi.enabled: true`로 렌더링하면
[`scripts/platform-services.sh`](scripts/platform-services.sh)가 HA 사전 검사, 고정 버전
ORC·CAPI·CAPO 설치, Magnum용 장기 ServiceAccount kubeconfig 생성, Kolla Magnum·Octavia
배포·재설정과 상태 검사를 담당한다. `apply`와 `reconfigure`는 `plan`이 출력한 정확한
`PLATFORM_SERVICES_CONFIRM` 값이 필요하다. 운영 진입점은 `scripts/cluster.sh`의
`platform-plan`, `platform-apply`, `platform-reconfigure`, `platform-status`다.

플랫폼 설치 전에 management Kubernetes control plane VM을 세 대로 확장하고
`cluster.sh prepare-k8s-cloud`로 현재 프로젝트에 전용 non-admin `member` 사용자를 만들고 그
사용자의 restricted OpenStack application credential을 한 번 생성한다. 첫 실행은 정확한
`MANAGEMENT_CLOUD_CONFIRM` 값만 출력하고, 그 값을 검토해 다시 실행해야 사용자와 credential을
만든다.
기존 `k8s-01`의 `fast` boot volume은 유지하고 새 `k8s-02`, `k8s-03`만 Ceph volume으로
만든다. Magnum 플래그가 켜진 상태에서 `deploy-kubernetes`를 실행하면 Kubespray 입력에
external OpenStack CCM, Cinder CSI의 기본 `ceph` StorageClass와 Octavia OVN LoadBalancer
설정이 자동으로 추가된다. 상세 절차는
[managed services 문서](docs/managed-services.md)에 있다.

관리 Kubernetes API는 `cluster.api_vip:6443`의 Kolla HAProxy listener를 통해 세 control
plane으로 전달된다. Magnum kubeconfig는 이 HA 주소를 사용한다. Kubespray 적용 상태
`state/kubespray/openstack/applied-nodes.json`, `kubeconfig/admin.conf`,
`kolla/generated/magnum/kubeconfig`, `kubeconfig/openstack-management.env`는 함께 백업한다.

`container_service.enabled`는 Kubernetes 기반 container-runtime API가 구현될 때까지
`false`로 유지한다. 호환되는 workload image를 Glance에 등록하고 Magnum cluster template을
만드는 작업과 첫 cluster의 생성·접속·확장·업그레이드·삭제 lifecycle 검증, k0smotron
provider와 실제 Hosted Control Plane, 자체 포털은 후속 작업이다. `cluster.sh hosted-plan`은
k0smotron v2.3.0 scaffold만 `.cache/platform/`에 만들며 클러스터에 적용하지 않는다.

## cloud01 디스크 계획

장치명은 바뀔 수 있으므로 설치와 초기화는 시리얼을 기준으로 한다.

| 시리얼 | 용도 | 배치 |
| --- | --- | --- |
| `EXAMPLE-OS-SSD-0001` | Ubuntu Server OS 128GB SSD | EFI 1GiB, `/boot` 2GiB, root 64GiB, `/var/log` 20GiB, swap 8GiB, 나머지 VG 여유 공간 |
| `EXAMPLE-DATA-SSD-0001` | OpenStack 데이터 1TB SSD | `/var/lib/docker` 256GiB, 나머지 `cinder-ssd` (`standard`) |
| `EXAMPLE-FAST-NVME-0001` | VM 볼륨 2TB NVMe | `cinder-nvme` (`fast`) |
| `EXAMPLE-RESERVED-SSD-0001` | 보류 512GB SSD | 초기화·마운트하지 않음 |
| `EXAMPLE-RESERVED-HDD-0001` | 보류 4TB HDD | 초기화·마운트하지 않음 |
| `EXAMPLE-RESERVED-HDD-0002` | 보류 3TB HDD | 초기화·마운트하지 않음 |

128GB 제조사 표기 디스크는 Linux에서 약 119GiB로 보이며 약 24GiB를 `ubuntu-vg`의 여유
공간으로 남긴다. 1TB SSD의 `standard` 영역은 약 675GiB, 2TB NVMe의 `fast` 영역은 포맷 전
약 1.82TiB다.

표의 값은 공개 예시다. 실제 시리얼은 `inventory/openstack-plan.local.yml`에 기록하며
`cloud01` 전용이다. 새 물리 노드에서
[`scripts/prepare-openstack-storage.sh`](scripts/prepare-openstack-storage.sh)를 실행해서는 안
된다. 추가 노드는 실제 장비의 디스크를 별도로 조사하고 `/var/lib/docker` 용량을 준비해야 한다.

## 네트워크 계획

| 네트워크 | 주소 | 용도 |
| --- | --- | --- |
| 관리망 | `192.0.2.0/24` | Ubuntu, SSH, OpenStack API |
| OpenStack API VIP | `192.0.2.10` | Kolla 내부·외부 API와 Skyline (`:9999`) |
| provider VLAN 10 | `198.51.100.0/24` | router `.2`, Floating IP `.50-.99`와 외부 연결 |
| Kubernetes tenant 망 | `203.0.113.0/24` | Kubernetes VM 사설 주소 |
| Kubernetes API VIP | `203.0.113.10` | kube-vip 내부 주소 |

각 OpenStack 노드의 관리 NIC는 `mgmt0`, VLAN 10 인터페이스는 `mgmt0.10`으로 구성한다.
스위치 포트는 untagged 관리망과 tagged VLAN 10을 모두 전달해야 한다. 관리 주소는
`cloud01=192.0.2.2`, `cloud02=192.0.2.4`, `cloud03=192.0.2.5`를 예약한다.

현재 한 노드에서는 관리·API·OVN tunnel이 `mgmt0`을 공유한다. 세 노드와 Ceph로 전환할 때는
별도 NIC의 Ceph public망을 우선 추가하고, 필요하면 OVN tunnel VLAN을 분리한다. VLAN별
스위치·라우터·ACL, NIC 수에 따른 단계안과 MTU 원칙은
[망분리 설계](docs/network-segmentation.md)에 정리했다.
OpenWrt를 라우터로 사용하는 현재 구성의 discovery, guarded apply와 rollback 절차는
[OpenWrt Provider VLAN 자동화](docs/openwrt-router.md)에 정리했다.

기본 Neutron backend는 처음부터 OVN이다. 미래의 Kubernetes `LoadBalancer` 구현은 Octavia
OVN provider를 사용하며, 한 노드 설치에서는 Octavia를 켜지 않는다. 설정 근거는
[Kolla-Ansible Neutron OVN 문서](https://docs.openstack.org/kolla-ansible/latest/reference/networking/neutron.html)와
[Octavia OVN provider 문서](https://docs.openstack.org/kolla-ansible/latest/reference/networking/octavia.html)다.

## 실행 진입점

처음 설치하는 순서는 [설치 런북](docs/openstack-runbook.md)에 있다. 주요 명령은 다음과 같다.

| 명령 | 역할 |
| --- | --- |
| `./scripts/cluster.sh validate` | 노드 정의와 역할 검증 |
| `./scripts/cluster.sh setup` | 고정 버전 Kolla 도구와 비밀번호 준비 |
| `./scripts/cluster.sh prepare-hosts` | playbook 자체 become으로 활성 Ubuntu 호스트 준비 |
| `./scripts/cluster.sh verify-hosts` | playbook 자체 become으로 호스트명, NIC, 시간, Docker 마운트와 LVM 확인 |
| `./scripts/cluster.sh openwrt-discover` | OpenWrt 장비·DSA·방화벽 정보를 읽기 전용으로 수집 |
| `./scripts/cluster.sh openwrt-plan` | OpenWrt VLAN 10 후보 설정과 장비 결합 확인값 생성 |
| `./scripts/cluster.sh openwrt-apply` | 백업·자동 rollback guard·노드 probe 후 OpenWrt 적용 확정 |
| `./scripts/cluster.sh openwrt-status` | 마지막 OpenWrt 계획과 현재 설정 대조 |
| `./scripts/cluster.sh openwrt-rollback` | 아직 guard가 켜진 OpenWrt transaction 수동 복원 |
| `sudo ./scripts/cluster.sh deploy-openstack` | 현재 토폴로지에 OpenStack 최초 배포 |
| `sudo ./scripts/cluster.sh expand-openstack` | 기존 cloud01을 3노드 이상으로 확장 |
| `sudo ./scripts/cluster.sh verify-openstack` | API와 등록된 OpenStack 서비스 확인 |
| `./scripts/cluster.sh terraform-plan` | Kubernetes VM 인프라 계획 저장 |
| `./scripts/cluster.sh terraform-apply` | 확인된 Terraform 계획 적용 |
| `./scripts/cluster.sh deploy-kubernetes` | Kubespray 설치 또는 확장 |
| `./scripts/cluster.sh prepare-k8s-cloud` | management K8s용 전용 non-admin 사용자와 credential 생성 |
| `sudo ./scripts/cluster.sh platform-plan` | 3노드·Ceph·management K8s 사전 검사와 확인 문자열 출력 |
| `sudo ./scripts/cluster.sh platform-apply` | 고정 버전 CAPI/CAPO와 Magnum·Octavia 최초 배포 |
| `sudo ./scripts/cluster.sh platform-reconfigure` | provider reconcile과 Magnum·Octavia 재설정 |
| `sudo ./scripts/cluster.sh platform-status` | CAPI, Magnum credential, OpenStack endpoint 상태 확인 |
| `sudo ./scripts/cluster.sh hosted-plan` | k0smotron Hosted Control Plane 검토용 scaffold 생성 |

Kolla `passwords.yml`, OpenStack `clouds.yaml`, Terraform 상태, SSH 개인키, Ceph keyring과
kubeconfig는 Git에 저장하지 않는다. 파일별 보관 위치와 복구 기준은
[로컬 전용 설정, 인증정보와 운영 상태](docs/local-secrets-and-state.md)를 따른다.

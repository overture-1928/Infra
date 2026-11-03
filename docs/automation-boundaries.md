# 자동화 범위와 안전 경계

이 저장소는 반복 가능한 검증과 배포 순서를 제공한다. 물리 디스크 초기화, OpenStack 제어
계층 확장, Terraform 적용, Kubernetes control plane 확장과 Ceph OSD 생성은 서로 다른 확인
경계를 사용한다. 한 단계의 확인 문자열이 다른 단계의 권한을 대신하지 않는다.

## 명령별 영향

| 명령 | 수행 내용 | 변경 범위 |
| --- | --- | --- |
| `cluster.sh validate` | 토폴로지 구조, 역할, 주소와 스토리지 모드 검사 | 읽기 전용 |
| `cluster.sh setup` | Python venv, Kolla 도구, Galaxy 의존성과 최초 비밀번호 준비 | 저장소의 `.cache/`, `kolla/generated/` |
| `cluster.sh render` | Ansible·Kolla·Ceph 입력 생성 | Git에서 제외된 생성물 |
| `cluster.sh prepare-hosts` | 일반 사용자 실행, playbook 자체 become으로 패키지·호스트명·Netplan·IOMMU·sysctl 설정 | 활성 Ubuntu 호스트 |
| `cluster.sh verify-hosts` | 일반 사용자 실행, playbook 자체 become으로 호스트명·NIC·시간·Docker·LVM 검사 | 읽기 중심 |
| `cluster.sh openwrt-discover` | OpenWrt board·DSA·UCI metadata와 설정 해시 수집 | 읽기 전용 |
| `cluster.sh openwrt-plan` | 장비·망 계획과 결합된 UCI batch·확인값 생성 | `.cache/openwrt/`만 변경 |
| `cluster.sh openwrt-apply` | 백업·timed rollback을 건 뒤 VLAN 10 적용과 노드 probe | OpenWrt network·firewall·DHCP |
| `cluster.sh openwrt-status` | 마지막 계획의 UCI와 interface 상태 검사 | 읽기 전용 |
| `cluster.sh openwrt-rollback` | 아직 armed 상태인 transaction의 `/etc/config` 복원 | OpenWrt network·firewall·DHCP |
| `cluster.sh deploy-openstack` | Kolla bootstrap 후 최초 OpenStack 배포 | 현재 토폴로지 전체 |
| `cluster.sh expand-openstack` | DB 백업 후 기존 OpenStack에 노드와 서비스 추가 | 현재 OpenStack 제어 계층 |
| `cluster.sh verify-openstack` | API와 등록 서비스 조회 | 읽기 전용 |
| `cluster.sh terraform-plan` | Kubernetes/platform root의 Terraform 계획을 `.cache/cluster/`에 저장 | OpenStack 자원 변경 없음 |
| `cluster.sh terraform-apply` | Kubernetes/platform root의 저장된 같은 계획 적용 | OpenStack 네트워크·볼륨·management VM |
| `cluster.sh workload-new <stack>` | 추적되는 템플릿에서 서비스 전용 Terraform root와 mode `0600` 변수 파일 생성 | 저장소의 `terraform/workloads/<stack>/` |
| `cluster.sh workload-plan <stack>` | 서비스 전용 plan을 원자적으로 저장하고 SHA-256 확인값 출력 | OpenStack 자원 변경 없음 |
| `cluster.sh workload-show <stack>` | 저장된 workload plan, SHA-256과 현재 확인값 표시 | OpenStack 읽기 전용; 로컬 provider 초기화 가능 |
| `cluster.sh workload-apply <stack>` | 확인된 같은 plan을 workload 공용 lock과 `parallelism=1`로 적용 | 해당 스택의 OpenStack VM·볼륨·포트 |
| `cluster.sh workload-output <stack>` | 해당 스택의 local 또는 remote backend에서 출력 조회 | OpenStack 읽기 전용; 로컬 provider 초기화 가능 |
| `cluster.sh deploy-kubernetes` | Kubespray 최초 설치 또는 scale | Kubernetes VM |
| `ceph-cluster.sh osd-apply` | 검토된 장치에 Ceph OSD 생성 | 지정한 물리 디스크 삭제 |
| `cluster.sh prepare-k8s-cloud` | management K8s용 non-admin 사용자와 application credential 생성 | OpenStack 사용자·credential과 로컬 secret |
| `cluster.sh platform-plan` | 3노드·Ceph·management K8s·OVN 조건 검사 | 읽기 중심 |
| `cluster.sh platform-apply` | ORC·CAPI·CAPO 설치 후 Magnum·Octavia 최초 배포 | management K8s와 OpenStack 서비스 |
| `cluster.sh platform-reconfigure` | provider reconcile 후 Magnum·Octavia 재설정 | management K8s와 OpenStack 서비스 |
| `cluster.sh platform-status` | controller, credential, endpoint와 OVN provider 검사 | 읽기 전용 |
| `cluster.sh hosted-plan` | k0smotron 검토용 manifest 렌더링 | `.cache/platform/`만 변경 |

`prepare-hosts`는 Netplan을 생성하지만 재부팅하지 않는다. 변경된 호스트를 재부팅한 뒤
`verify-hosts`가 성공해야 Kolla 배포를 진행한다. 두 명령은 wrapper에 `sudo`를 붙이지 않고
일반 `operator` 사용자로 실행한다. playbook의 `become: true`가 원격 권한 상승을 담당한다.
cloud01 자동 설치는 이를 위해 `operator` 전용 NOPASSWD sudoers 파일을 만들고 `visudo`로
검사한다. 추가 노드에도 같은 공개키와 암호 없는 sudo가 준비되어 있어야 한다.

OpenWrt 적용은 별도의 장비·포트 결합 확인값을 요구한다. 전체 `sysupgrade` 백업과
`/etc/config` 백업을 만든 뒤에만 UCI를 commit하며, 라우터와 활성 OpenStack 노드의 tagged
VLAN probe가 모두 성공해야 rollback guard를 해제한다. 첫 DSA 변경에는 로컬 또는 serial
console을 확보해야 한다. 상세 경계는 [OpenWrt Provider VLAN 자동화](openwrt-router.md)를
따른다.

`deploy-openstack`, `expand-openstack`, `platform-apply`, `platform-reconfigure`와 직접 실행하는
root 전용 `openstack.sh` Kolla 작업은 로컬 root의 SSH trust context를 사용한다. SSH 연결
노드가 있으면 검토한 지문을 `/root/.ssh/known_hosts`에 미리 등록하거나
`ANSIBLE_SSH_COMMON_ARGS='-o UserKnownHostsFile=/home/operator/.ssh/known_hosts'`처럼 검토한
파일을 명시하고 `sudo --preserve-env=ANSIBLE_SSH_COMMON_ARGS`로 전달한다. 일반 사용자의
`known_hosts`만 준비한 상태로 root Kolla 작업을 시작하지 않으며 host key 검사를 끄지 않는다.

## 디스크를 지우는 경계

### Ubuntu 자동 설치

`ubuntu-autoinstall/user-data.template`은 로컬 인벤토리에 기록한 OS 디스크 시리얼을 선택하고
해당 디스크를 초기화한다. 자동 설치 seed는 cloud01 전용이다. 운영자가 ISO와 seed를
연결하고 실제 부팅을 선택해야 실행된다.

### cloud01 OpenStack LVM

`prepare-openstack-storage.sh`는 기본적으로 점검만 수행한다. 적용에는 다음 문자열과
`--apply`가 모두 필요하다.

```bash
export OPENSTACK_STORAGE_CONFIRM='WIPE-OPENSTACK-STORAGE:<출력된 데이터 SSD 시리얼>:<출력된 고속 NVMe 시리얼>'
sudo --preserve-env=OPENSTACK_STORAGE_CONFIRM ./scripts/prepare-openstack-storage.sh --apply
```

대상은 고정된 1TB SSD와 2TB NVMe다. 새 노드의 디스크를 준비하는 범용 스크립트가 아니다.

### Ceph OSD

Ceph 입력은 각 장치를 `/dev/disk/by-id`, 시리얼, 최소 크기와 class로 고정한다.
`osd-plan`이 만든 manifest와 SHA-256을 검토한 뒤에만 적용한다.

```bash
export OPENSTACK_CLUSTER_CONFIG=inventory/openstack-cluster.ceph.local.yml
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG ./scripts/ceph-cluster.sh osd-plan
cat .cache/ceph/ceph-osd-manifest.txt
cat .cache/ceph/ceph-osd-manifest.sha256

export CEPH_OSD_CONFIRM='WIPE-CEPH-OSDS:<검토한-sha256>'
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,CEPH_OSD_CONFIRM ./scripts/ceph-cluster.sh osd-apply
```

manifest 내용이 바뀌면 SHA-256과 확인 문자열도 바뀐다. preflight는 파티션, 파일시스템,
LVM, 서명, mount, swap 또는 holder가 있는 장치를 거부한다. `osd-apply`는 이 검사를 다시
통과한 빈 전체 디스크만 Ceph OSD로 소비한다.

현재 OSD workflow는 빈 디스크로 시작하는 최초 Ceph 구성용이다. 이미 BlueStore OSD로 사용
중인 장치를 topology에 둔 채 새 OSD를 추가하면 기존 장치도 빈 디스크 preflight 대상이 되어
중단된다. 기존 3노드 Ceph에 5·7번째 노드의 OSD만 증설하는 add-only workflow는 아직 구현되지
않았으므로 `osd-apply`를 반복 실행하지 않는다.

## 제어 계층을 바꾸는 경계

### OpenStack 1노드에서 3노드 이상으로 확장

`expand-openstack`은 렌더링된 모든 활성 물리 노드의 정확한 목록을 요구한다. 다음은 최초
3노드 확장의 예다.

```bash
export OPENSTACK_EXPAND_CONFIRM='EXPAND-OPENSTACK:cloud01,cloud02,cloud03'
sudo --preserve-env=OPENSTACK_EXPAND_CONFIRM ./scripts/cluster.sh expand-openstack
```

5노드라면 확인값은 `EXPAND-OPENSTACK:cloud01,cloud02,cloud03,cloud04,cloud05`가 된다.
컨트롤러 3대를 그대로 두고 compute 노드만 추가해도 확인 문자열이 바뀐다.

명령은 MariaDB 전체 백업 후 Kolla bootstrap과 deploy를 실행한다. bootstrap 과정에서 Docker
엔진과 컨테이너가 다시 시작될 수 있으므로 유지보수 시간에 수행한다. 백업을 외부 저장소로
복사하거나 복원 시험을 수행하는 일은 자동화 범위에 포함되지 않는다.

현재 고정 버전은 Kolla-Ansible 23.0.0과 OpenStack 2026.2다. `openstack.sh bootstrap`은
`bootstrap-servers`, `gather-facts`는 Kolla 사실 수집, `deploy`는 prechecks·pull·deploy·
post-deploy를 실행한다. `reconfigure`는 검토된 설정 변경용이며 새 물리 호스트 편입을
대신하지 않는다. `cluster.sh expand-openstack`은 이 순서를 전체 렌더링 인벤토리에 적용한다.

`cluster.platform.magnum_capi.enabled: true`인 운영 클라우드에서는 일반
`expand-openstack`을 차단한다. `platform-reconfigure`도 새 호스트 bootstrap을 대신하지 않으므로
Magnum/CAPI 활성화 이후의 물리 노드 편입은 현재 자동화 범위 밖이다. 가능하면 목표 5·7노드를
먼저 OpenStack에 편입하고 Ceph와 관리형 플랫폼을 활성화한다.

저장소에는 Kolla destroy 명령을 제공하지 않는다. 노드 제거, 컨트롤러 축소와 기존
인벤토리 호스트 이름 변경도 자동화하지 않는다.

### Ceph 클러스터 생성과 풀

Ceph는 OpenStack 확장과 별도 workflow다. 기존 LVM 클라우드에서는 별도 입력 파일을 사용한다.

Ceph bootstrap 호스트에는 컨테이너 이미지와 같은 20.2.4 버전의 cephadm을 체크섬 검증 후
설치한다.

```bash
sudo ./scripts/ceph-cluster.sh setup
```

```bash
export OPENSTACK_CLUSTER_CONFIG=inventory/openstack-cluster.ceph.local.yml
./scripts/ceph-cluster.sh validate
./scripts/ceph-cluster.sh preflight
```

Ceph bootstrap은 정확한 호스트 목록을 요구한다.

```bash
export CEPH_BOOTSTRAP_CONFIRM='BOOTSTRAP-CEPH:cloud01,cloud02,cloud03'
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,CEPH_BOOTSTRAP_CONFIRM ./scripts/ceph-cluster.sh bootstrap
```

bootstrap 호스트에 기존 `/etc/ceph/ceph.conf` 또는 `/var/lib/ceph/<FSID>` 상태가 있으면 새
클러스터 생성을 거부한다. 전용 정리·복구 절차 없이 기존 Ceph 상태를 덮어쓰지 않는다.

호스트 추가와 상태 확인 후 OSD를 적용한다.

```bash
export CEPH_HOSTS_CONFIRM='ADD-CEPH-HOSTS:cloud01,cloud02,cloud03'
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,CEPH_HOSTS_CONFIRM ./scripts/ceph-cluster.sh add-hosts
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG ./scripts/ceph-cluster.sh status
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG ./scripts/ceph-cluster.sh osd-plan
# 검토한 CEPH_OSD_CONFIRM으로 osd-apply
```

복제 크기 3, 최소 복제본 2의 OpenStack 풀 구성에도 선택한 장치 class가 들어간 별도 확인
문자열을 사용한다. 기본 topology의 `openstack_pool_device_class`는 `nvme`다.

```bash
export CEPH_POOL_CONFIRM='CONFIGURE-CEPH-POOLS:nvme:size3:min2'
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,CEPH_POOL_CONFIRM ./scripts/ceph-cluster.sh configure-pools

export CEPH_EXPORT_CONFIRM='EXPORT-KOLLA-CEPH-CLIENTS'
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,CEPH_EXPORT_CONFIRM ./scripts/ceph-cluster.sh export-kolla
```

`configure-pools`는 선택한 `hdd`, `ssd`, `nvme` class가 서로 다른 세 OSD 호스트에서
`up/in`이고 Ceph 상태가 `HEALTH_OK`일 때만 `images`, `volumes`, `vms` 풀을 만든다. 세 풀은 해당 class와
host failure domain을 사용하는 전용 CRUSH rule에 고정된다. `ceph_osd_devices: []`인
compute-only 노드는 OSD preflight, manifest와 cephadm host 등록 대상에서 제외된다.

`export-kolla`는 Kolla용 `ceph.conf`와 최소 권한 서비스 keyring을
`kolla/generated/ceph-config/`에 쓴다. Kolla reconfigure나 데이터 이전은 실행하지 않는다.

기존 LVM 클라우드에서는 다음 경계를 지킨다.

1. 기본 `openstack-cluster.local.yml`은 LVM 상태로 유지한다.
2. Ceph 전용 `openstack-cluster.ceph.local.yml`은 Ceph 명령에만 전달한다.
3. Ceph 전용 입력으로 `cluster.sh deploy-openstack`과 `expand-openstack`을 실행하지 않는다.
4. 운영자가 hybrid Kolla 설정을 만들어 LVM·iSCSI와 Ceph backend를 함께 활성화한다.
5. 새 Ceph 자원의 생성·연결·복구를 시험한 뒤 기존 데이터를 수동 이전한다.
6. 모든 이전과 복원 시험이 끝난 뒤 별도 변경으로 LVM backend를 비활성화한다.

Ceph 스크립트는 LVM 볼륨, Glance 이미지, VM ephemeral disk를 옮기지 않으며 기존 Cinder VG를
지우지 않는다.

아직 OpenStack 데이터가 없는 신규 3노드 설치만 기본 토폴로지를 처음부터 Ceph로 설정할 수
있다. 이 경우에도 Ceph 클러스터와 client 설정을 먼저 준비하고 렌더링된 Ceph 전용 Kolla
설정을 검토한 뒤 최초 배포한다. 이 절차를 운영 중인 LVM 클라우드에 적용하지 않는다.

## OpenStack 자원과 Kubernetes 경계

`terraform/openstack/`은 management Kubernetes와 공용 기반 자원의 root/state다. 일반 VM을
여기에 추가하면 Kubernetes 변경과 애플리케이션 VM 변경이 같은 plan과 state에 섞이므로,
일반 VM은 `terraform/workloads/<stack>/`의 독립 root로 관리한다. 공통 모듈과 서비스별 구조는
[서비스별 OpenStack VM Terraform 스택](terraform-workloads.md)에 정리되어 있다.

workload 스택 이름은 `^[a-z0-9][a-z0-9-]{0,62}$` 형식의 1∼63자만 허용한다. `_template`
자체와 기존 경로는 생성 대상으로 받을 수 없다. `workload-new`가 만든 `terraform.tfvars`는
mode `0600`이며 첫 검사는 `enable_instances = false` 상태에서 수행한다. OpenStack CLI로
인증과 조회 권한을 먼저 확인하고, 조회한 network·subnet·image UUID와 Nova flavor ID를 입력한다.
첫 Terraform plan이 자원 생성을 포함하지 않는지 확인한 뒤에만 활성화한다.

workload wrapper는 기본 Terraform workspace와 고정 `terraform.tfvars`만 허용한다.
`TF_CLI_ARGS*`, `TF_DATA_DIR`, `TF_REATTACH_PROVIDERS`, `TF_WORKSPACE`, `TF_VAR_*`, ignored auto
tfvars와 override 파일은 state 경로, locking 또는 검토 입력을 우회할 수 있으므로 거부한다.

`workload-plan`은 임시 파일에 성공적으로 만든 plan을 mode `0600`으로 원자 교체해
`.cache/terraform/workloads/<stack>.tfplan`에 저장한다. plan SHA-256과 현재 OpenStack
credential/config 환경의 지문은 같은 경로의 `<stack>.tfplan.context.json`에 mode `0600`으로
저장한다. 지문에는 provider가 workload root, 사용자 config, `/etc/openstack`에서 실제 선택하는
secure/public cloud 파일과 YAML이 참조하는 절대경로 인증서·키 내용도 들어간다.
`workload-show`가 `terraform init` 전에 동일한 context임을 확인하고 표시한 정확한 plan을
검토한 뒤 다음 형식의 출력값을 현재 shell에 설정한다.

```text
TERRAFORM_WORKLOAD_APPLY_CONFIRM=APPLY-TERRAFORM-WORKLOAD:<stack>:<plan-sha256>
```

`workload-apply`는 workload 스택이 공유하는 Terraform lock을 얻고 plan의 현재 SHA-256과
credential context를 다시 확인한 뒤 정확히 일치하는 저장 plan만 `parallelism=1`로 적용한다.
Terraform도 state가 plan 이후 바뀌었으면 stale plan을 거부한다. 코드, 변수, credential 또는
실제 자원 조건이 달라졌다면 적용을 반복하지 말고 새 plan을 만들고 다시 검토한다.
`workload-output`은 해당 root가 구성한 backend에서 출력을 조회한다. 이 wrapper lock은 한
checkout 안에서만 동작하므로 여러 checkout이나 운영자는 locking을 지원하는 remote backend를
사용해야 한다.

각 스택의 `instances` map key는 Terraform 주소이므로 운영 중 이름을 바꾸지 않는다. key 삭제,
`enable_instances = false` 전환과 VM·root volume 교체는 두 자원의 삭제를 계획하지만 공통
모듈의 `prevent_destroy`가 적용을 차단한다. Port, security group과 Floating IP에는 같은 보호가
없으므로 plan에서 교체·삭제를 따로 확인한다. 자동 `workload-destroy` 명령은 제공하지 않는다.
의도적인 폐기는 데이터 이전·백업·복원 시험을 먼저 끝낸다. 그다음 정확한 스택과 key,
lifecycle 보호 처리, Terraform resource 주소, 실제 삭제 대상과 복구 방법을 명시한 별도 변경을
검토해야 한다. 이 저장소는 범용 폐기 명령이나 자동 절차를 제공하지 않으며 `terraform destroy`,
`state rm` 또는 `-target`을 표준 폐기 절차로 자동화하지 않는다.

workload state, `terraform.tfvars`와 cloud credential은 Git에 포함하지 않고 암호화해 백업한다.
cloud-init secret은 plan과 state에도 남을 수 있으므로 비밀번호, 장기 token, SSH 개인키와
application credential secret을 넣지 않는다. 구체적인 파일 목록은
[로컬 전용 설정, 인증정보와 운영 상태](local-secrets-and-state.md)를 따른다.

Terraform은 `enable_resources=false`가 기본이다. `terraform-plan`이 저장한 계획을 검토한
뒤 다음 확인 문자열로 같은 계획을 적용한다.

```bash
export TERRAFORM_APPLY_CONFIRM=APPLY-KUBERNETES-INFRA
./scripts/cluster.sh terraform-apply
```

Terraform 리소스의 VM과 부팅 볼륨에는 `prevent_destroy`가 설정되어 있다. 자동 노드 제거는
제공하지 않는다.

Kubespray 자동화는 기존 노드 제거와 역할 제거를 차단한다. control plane 또는 etcd 역할을
추가할 때 스크립트가 현재 변경 대상에 맞는 다음 형태의 확인 문자열을 출력한다.

```text
KUBERNETES_CONTROL_PLANE_SCALE_CONFIRM=SCALE-KUBERNETES-CONTROL:<노드목록>
```

출력된 정확한 값을 설정한 뒤 `cluster.sh deploy-kubernetes`를 다시 실행한다.

Magnum/CAPI 프로필에서는 Kubernetes 확장 전에 `cluster.sh prepare-k8s-cloud`를 실행한다.
첫 실행은 현재 admin cloud의 프로젝트 ID를 확인하고 정확한
`MANAGEMENT_CLOUD_CONFIRM=CREATE-K8S-CLOUD-PRINCIPAL:<project-id>:kubespray-management:member`
값을 출력한 뒤 중단한다. 이 값을 검토해 두 번째 실행에 전달해야 현재 프로젝트의 전용
non-admin `member` 사용자와 restricted application credential을 만든다. 임의 비밀번호는
credential 발급 뒤 폐기하고 one-time secret은
`kubeconfig/openstack-management.env`에 mode `0600`으로 저장한다. secret을 출력하지 않으며,
동일한 원격 사용자나 로컬 파일이 있으면 삭제·재설정·교체·회전하지 않고 중단한다.
생성 중 실패하면 이번 실행에서 만든 전용 사용자만 롤백하며, 기존 자원은 삭제하지 않는다.
admin cloud의 `cacert`가 있으면 credential 환경에도 보존한다.

Magnum 플래그가 켜진 상태에서 `deploy-kubernetes`를 실행하면 Kubespray renderer는 다음
설정을 자동으로 만든다.

- external OpenStack cloud provider
- controller replica 3의 Cinder CSI
- `ceph` volume type을 쓰는 default `cinder-csi` StorageClass
- provider가 `ovn`인 external OpenStack LoadBalancer와 Terraform network/subnet ID

따라서 플랫폼 순서는 `magnum_capi.enabled=true` 렌더링, management control plane VM 세
대의 Terraform 적용, `prepare-k8s-cloud`, `deploy-kubernetes`, `platform-plan`, 확인된
`platform-apply`, `platform-status`다. 기존 `k8s-01`의 `fast` boot volume은 유지하고 새
`k8s-02`, `k8s-03`만 Ceph를 사용한다. 기존 boot volume의 Ceph 이전은 `prevent_destroy`가
자동 교체를 차단하므로 별도 Cinder/VM migration과 복구 시험으로 수행한다. credential
파일은 Kubernetes 배포와 복구에 필요한 secret backup 대상이다.
`state/kubespray/openstack/applied-nodes.json`, `kubeconfig/admin.conf`와 이후 생성되는
`kolla/generated/magnum/kubeconfig`도 같은 복구 세트로 백업한다.

## 플랫폼 서비스와 버전 경계

Kubespray가 만드는 최초 클러스터는 management/hosting cluster의 부트스트랩이다. 현재
한 물리 노드에서는 Skyline/OpenStack API, 핵심 OpenStack과 이 부트스트랩 클러스터까지만
구성한다. 3노드·Ceph 조건을 만족하면 별도 platform 명령이 management cloud 연동과
Magnum/Octavia 기반까지 확장한다.

Neutron backend는 최초 OpenStack 배포부터 OVN으로 고정한다. 미래의 Kubernetes
`LoadBalancer`는 Octavia OVN provider로 제공해 운영 중 OVS→OVN 전환과 Amphora
image·certificate 준비를 피한다. 한 물리 노드에서는 Octavia와 Magnum managed-service
플래그를 비활성 상태로 유지한다. 3노드 OpenStack, Ceph 데이터 HA와 management cluster
복구가 모두 검증된 뒤에만 Octavia OVN provider와 Magnum/CAPI를 별도 변경으로 활성화한다.

이 저장소가 고정한 OpenStack/Kolla-Ansible 2026.2에는 Zun과 Kuryr 배포 지원이 없다.
Kolla-Ansible은 해당 지원을 2026.1부터 제거했으므로 노드 수와 관계없이 `enable_zun` 또는
`enable_kuryr`를 설정하지 않는다. ECS와 유사한 기능은 Kubernetes workload를 조정하는
별도 container-runtime API로 설계한다. Zun이 필수라면 2025.2 legacy 프로필을 별도
클러스터·별도 수명주기로 채택할지 먼저 결정해야 한다.

Magnum의 Heat driver는 2026.2에서 제거되었다. Kolla 2026.2 Magnum 이미지에는 VEXXHOST
`magnum-cluster-api` driver가 포함되어 있다. EKS와 유사한 서비스는 Magnum API와 이
`k8s_cluster_api` driver를 사용하고, CAPI controller와 CAPO가 요청을 OpenStack
VM·네트워크·볼륨으로 구현한다.

`cluster.sh platform-plan`은 내부 `platform-services.sh`를 통해 다음 조건을 모두 검사한다.

- 렌더링된 토폴로지가 세 물리 노드 이상이고 Ceph backend를 사용
- Ceph가 `HEALTH_OK`이며 서로 다른 세 호스트의 OSD가 `up/in`
- 선택한 OpenStack 풀 장치 class와 host failure-domain CRUSH rule, 세 RBD 풀 설정이 일치
- `cluster.platform.magnum_capi.enabled: true`
- management Kubernetes에 Ready control plane 세 대 이상
- management Kubernetes에 동적 provisioner를 쓰는 default StorageClass가 정확히 하나
- Terraform `management_api_address`와 `cluster.api_vip`가 일치
- 렌더링된 Kolla globals가 OVN, Magnum, Barbican과 OVN 전용 Octavia provider를 사용

`container_service.enabled`는 후속 Kubernetes container-runtime API가 구현될 때까지
`false`로 유지할 수 있다. `platform-plan`은 읽기 중심이며 다음 정확한 확인값을 출력한다.

```text
APPLY-MAGNUM-CAPI:v1.14.3:v1.14.3:v0.15.1:v2.6.0
RECONFIGURE-MAGNUM-CAPI:v1.14.3:v1.14.3:v0.15.1:v2.6.0
```

`platform-apply`와 `platform-reconfigure`에는 해당 값을 `PLATFORM_SERVICES_CONFIRM`으로
전달해야 한다.
자동화는 ORC v2.6.0, CAPI·clusterctl v1.14.3, kubeadm bootstrap/control-plane provider와
CAPO v0.15.1을 management cluster에 설치하거나 reconcile한다. 이어서 `magnum-capi`
ServiceAccount의 장기 token과 mode `0600` kubeconfig를 만들고 Kolla deploy 또는
reconfigure를 실행한다. 이 kubeconfig는 cluster-admin credential이므로 일반 사용자에게
배포하지 않는다. Kolla HAProxy는 `cluster.api_vip:6443`를 세 control-plane Floating IP로
전달하며 Magnum kubeconfig는 이 HA endpoint를 사용한다. 고정된 `clusterctl`, ORC manifest와
`kubectl` 다운로드는 SHA-256을 검증한다. 제거 명령과 자동 rollback은 제공하지 않는다.

관리형 프로필이 활성화되면 일반 `deploy-openstack`과 `expand-openstack`을 거부한다. CAPI
provider와 Magnum kubeconfig, HAProxy 설정을 함께 준비하는 `platform-apply` 또는
`platform-reconfigure`만 사용한다.

`platform-status`는 CAPI·CAPO·ORC deployment와 CRD, ServiceAccount token, 생성·설치된 kubeconfig,
Magnum·Octavia endpoint, OVN provider 등록과 `k8s_cluster_api` driver 상태를 읽어 검사한다.
호환되는 workload image의 Glance 등록, Magnum cluster template 생성과 첫 cluster의
생성·접속·확장·업그레이드·삭제 lifecycle 검증, Kubernetes container-runtime API와 자체
포털은 후속 작업이다. 자체 포털은 Skyline과 OpenStack API를 대체하지 않고, 인프라 API와
container-runtime API를 호출하는 상위 사용자 진입점으로 둔다.

k0smotron v2.3.0은 management cluster 안에서 tenant control plane을 Pod로 운영하는 별도
control-plane provider다. OpenStack, Magnum, CAPI 또는 CAPO의 내장 기능이 아니다. 다음
조건을 충족한 후 별도 단계로 도입한다.

- 3노드 OpenStack 제어 계층 검증
- Ceph 데이터 HA와 복구 시험
- management cluster의 3노드 배치, 백업과 복구 절차
- tenant API endpoint와 LoadBalancer 설계
- k0smotron etcd PVC의 가용성과 백업 설계

`cluster.sh hosted-plan`은 `magnum_capi.hosted_control_plane: true`와 검토한
`HOSTED_K0S_VERSION`을 요구하고 `.cache/platform/k0smotron-*.yml`만 만든다. k0smotron
provider를 설치하거나 Hosted Control Plane manifest를 적용하지 않는다.

이 경계가 준비되기 전까지 최초 Kubespray 클러스터가 management 기능을 담당하며, workload
cluster와 플랫폼 서비스 생성은 자동으로 시작하지 않는다. 관련 버전 근거는
[Kolla-Ansible 2026.1 릴리스 노트](https://docs.openstack.org/releasenotes/kolla-ansible/2026.1.html),
[Magnum 2026.1 역할 문서](https://docs.openstack.org/openstack-ansible-os_magnum/2026.1/),
[VEXXHOST Magnum Cluster API driver](https://vexxhost.github.io/magnum-cluster-api/),
[Magnum Cluster API 시작 안내](https://vexxhost.github.io/magnum-cluster-api/user/getting-started/),
[Magnum workload image](https://vexxhost.github.io/magnum-cluster-api/user/images/),
[CAPO Hosted Control Plane](https://cluster-api-openstack.sigs.k8s.io/topics/hosted-control-plane),
[k0smotron v2.3.0](https://docs.k0smotron.io/v2.3.0/install/),
[Kolla-Ansible Neutron OVN](https://docs.openstack.org/kolla-ansible/latest/reference/networking/neutron.html),
[Octavia OVN provider](https://docs.openstack.org/kolla-ansible/latest/reference/networking/octavia.html)에 있다.

## 사람이 수행하는 검토

다음 항목은 자동화 결과만으로 완료로 간주하지 않는다.

- 외부 백업의 실제 복원
- 새 물리 노드의 디스크 라벨과 시리얼 대조
- SSH 호스트 지문 확인
- 스위치 trunk와 VLAN 설정
- 기존 VM·Neutron 자원 재분산
- LVM에서 Ceph로의 데이터 이전과 애플리케이션 일관성
- 물리 노드 장애, API VIP 이동과 데이터 복구 시험
- PCI 패스스루 VM의 별도 복구

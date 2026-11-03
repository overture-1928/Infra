# Ubuntu Server · OpenStack · Kubernetes 설치 런북

이 문서는 `cloud01`을 처음 설치해 OpenStack과 최초 Kubernetes 클러스터를 만드는 순서다.
디스크를 변경하는 단계는 정확한 시리얼과 별도 확인 문자열이 일치해야 실행된다. 필요한
데이터를 서버 외부로 복사하고 대표 파일의 복원을 확인한 뒤 시작한다. 실제 환경값을 기록할
파일과 비밀·상태의 백업 기준은 [로컬 전용 설정, 인증정보와 운영 상태](local-secrets-and-state.md)를
먼저 확인한다.

## 1. cloud01 하드웨어 확인

현재 장비에서 디스크 모델, 시리얼, SMART 상태를 실제 라벨과 대조한다.

```bash
sudo ./scripts/inspect-openstack-storage.sh
```

초기화 대상으로 검토된 장치는 다음 세 개다.

- Ubuntu OS: `EXAMPLE-OS-SSD-0001`
- OpenStack 운영 데이터와 일반 볼륨: `EXAMPLE-DATA-SSD-0001`
- 고속 Cinder 볼륨: `EXAMPLE-FAST-NVME-0001`

512GB SSD와 3TB·4TB HDD는 설치 프로그램과 스토리지 스크립트에서 사용하지 않는다.
위 시리얼은 공개 저장소용 예시다. 점검 결과와 장비 라벨을 대조한 다음 실제 입력 파일을
만들고 MAC 주소, 주소와 모든 디스크 시리얼을 이 장비 값으로 수정한다.

```bash
umask 077
test -e inventory/openstack-cluster.local.yml || \
  cp inventory/openstack-cluster.yml inventory/openstack-cluster.local.yml
test -e inventory/openstack-plan.local.yml || \
  cp inventory/openstack-plan.yml inventory/openstack-plan.local.yml
chmod 0600 \
  inventory/openstack-cluster.local.yml \
  inventory/openstack-plan.local.yml
${EDITOR:-vi} inventory/openstack-cluster.local.yml inventory/openstack-plan.local.yml
```

두 `.local.yml` 파일은 Git에서 제외된다. 자동 설치와 스토리지 초기화는 공개 예시 시리얼을
거부한다.

## 2. Ubuntu 자동 설치 seed

현재 저장소와 SSH 개인키를 서버 밖에 백업하고 실제 복원이 되는지 확인한다. seed를 만드는
작업용 Ubuntu PC에는 다음 도구가 필요하다.

```bash
sudo apt update
sudo apt install -y cloud-image-utils openssl python3-yaml
```

암호 해시와 SSH 공개키를 전달해 seed를 만든다.

```bash
export UBUNTU_OPERATOR_PASSWORD_HASH="$(openssl passwd -6)"
export UBUNTU_OPERATOR_SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
./scripts/render-ubuntu-autoinstall.sh
./scripts/build-autoinstall-seed.sh
```

Ubuntu Server 24.04 ISO와 생성된 `cloud01-autoinstall-seed.iso`를 연결한다. 부팅 항목의
커널 인자에 `autoinstall`이 포함됐는지 확인하고, 설치 화면에서 OS 디스크 시리얼이
`inventory/openstack-cluster.local.yml`에 기록한 실제 OS 디스크 시리얼인지 다시 확인한다.
이 seed는 cloud01의 호스트명, MAC, 주소와 디스크
시리얼을 포함하므로 새 물리 노드에 재사용하지 않는다. 저장소 구성은 GPT의 BIOS GRUB
영역과 EFI System Partition을 함께 만들므로 UEFI와 legacy BIOS 설치 경로를 모두 갖는다.

자동 설치는 SSH 공개키만 허용하고 `operator`에 Ansible용 암호 없는 sudo를 설정한다.
설치 후 저장소 자동화를 시작하기 전에 해당 권한과 sudoers 문법을 확인한다.

```bash
sudo -n true
sudo visudo -cf /etc/sudoers.d/90-operator-ansible
```

재부팅된 cloud01에서는 설치 전 작업용 PC의 저장소 경로를 사용하지 않는다. 자동 설치가 만든
`operator` 계정으로 저장소를 `/home/operator/Openstack`에 복원하고, 숨김 파일인
`terraform/openstack/.terraform.lock.hcl`도 포함됐는지 확인한다. SSH 개인키는 저장소 밖의
`/home/operator/.ssh/id_ed25519`에 mode `0600`으로 복원한다.

```bash
sudo chown -R operator:operator /home/operator/Openstack
chmod 0700 /home/operator/.ssh
chmod 0600 /home/operator/.ssh/id_ed25519
cd /home/operator/Openstack
test -f terraform/openstack/.terraform.lock.hcl
```

`.cache/`, Terraform state, kubeconfig와 Kolla 비밀번호 같은 실행 상태는 외부 백업에서
의도적으로 복원하는 경우가 아니면 새로 만든다. 이후 명령은 이 저장소 최상위에서 실행한다.

OS SSD에는 EFI 1GiB, `/boot` 2GiB, root 64GiB, `/var/log` 20GiB, swap 8GiB를 만든다.
128GB 제조사 표기 디스크는 Linux에서 약 119GiB로 보이며 약 24GiB를 `ubuntu-vg`에
할당하지 않은 채 남긴다.

## 3. 토폴로지와 Kolla 도구 준비

1단계에서 만든 로컬 입력을 다시 검토한다. 최초 설치에서는 기본값처럼
`cloud01.enabled: true`, `cloud02.enabled: false`, `cloud03.enabled: false`를 유지한다.

```bash
./scripts/cluster.sh validate
./scripts/cluster.sh setup
```

`setup`은 고정 버전 Kolla-Ansible, 지원 범위의 `ansible-core`와 체크섬으로 검증한 Terraform
CLI를 `.cache/`에 설치하고,
최초 한 번만 Kolla 비밀번호를 만든 뒤 인벤토리를 렌더링한다. 이후 실행에서도 기존
`kolla/generated/passwords.yml`을 유지한다.

렌더링 결과를 확인한다.

```bash
./scripts/cluster.sh render
sed -n '1,80p' kolla/inventory/multinode.local
sed -n '1,120p' .cache/cluster/ansible-inventory.yml
sed -n '1,180p' kolla/generated/globals.yml
```

단일 노드에서도 Kolla 인벤토리 이름은 `cloud01`이다. 나중에 확장할 때 이 이름을 바꾸지
않는다. 생성된 globals는 최초 배포부터 `neutron_plugin_agent: ovn`을 사용해야 한다.
한 노드 단계의 Octavia와 Magnum managed-service 플래그는 비활성 상태로 유지한다.

## 4. Ubuntu 호스트 준비

```bash
./scripts/cluster.sh prepare-hosts
sudo reboot
```

Ansible은 Ubuntu 버전과 자원을 확인하고 호스트명, `/etc/hosts`, 관리 NIC, VLAN 10,
시간 동기화, IOMMU와 필수 패키지를 설정한다. Kolla의 `iscsid` 컨테이너와 충돌하지 않도록
호스트 `iscsid`·`open-iscsi` unit과 socket activation은 중지·비활성화한다. Netplan은 생성만 하므로 재부팅 후 새
네트워크 구성이 활성화된다. 이 명령은 일반 `operator` 사용자로 실행하며 playbook 자체의
`become: true`가 자동 설치에서 만든 암호 없는 sudo 권한으로 시스템 변경을 수행한다.

재부팅 후 다음 상태를 확인한다.

```bash
hostname
ip -br address
timedatectl show --property=NTPSynchronized
```

`hostname`은 `cloud01`, `mgmt0`은 `192.0.2.2/24`, `mgmt0.10`은 IP 주소가 없는
상태여야 한다. 스위치 포트는 untagged 관리망과 tagged VLAN 10을 모두 전달해야 한다.
VLAN 10의 `198.51.100.1` gateway와 routing을 제공할 VLAN 지원 라우터도 필요하다. 현재
한 노드와 세 노드 목표의 전체 망 구성은 [망분리 설계](network-segmentation.md)를 따른다.

## 5. OpenWrt Provider VLAN 준비

OpenStack을 배포하기 전에 OpenWrt에 관리망 native VLAN과 Provider tagged VLAN 10을
구성한다. 먼저 읽기 전용 discovery를 실행하고 실제 모델, DSA bridge와 물리 포트를 로컬
인벤토리에 적는다.

```bash
umask 077
test -e inventory/openwrt-router.local.yml || \
  cp inventory/openwrt-router.example.yml inventory/openwrt-router.local.yml
chmod 0600 inventory/openwrt-router.local.yml
./scripts/cluster.sh openwrt-discover
```

복구 콘솔과 스위치 trunk를 준비한 뒤 계획을 만들고 `.cache/openwrt/uci.batch`를 검토한다.

```bash
./scripts/cluster.sh openwrt-plan
cat .cache/openwrt/uci.batch
```

계획이 출력한 실제 `OPENWRT_APPLY_CONFIRM`과 `OPENWRT_CONFIRM`을 설정한 뒤 적용한다. 자동화는
백업과 rollback guard를 먼저 만들고, 라우터 설정과 `cloud01`의 `mgmt0.10`에서 gateway
통신이 모두 확인된 경우에만 변경을 확정한다.

```bash
export OPENWRT_APPLY_CONFIRM='APPLY-OPENWRT:<plan이 출력한 실제 값>'
export OPENWRT_CONFIRM='CONFIRM-OPENWRT:<plan이 출력한 실제 값>'
./scripts/cluster.sh openwrt-apply
```

장비별 값, 관리형 스위치 설정과 복구 절차는 [OpenWrt Provider VLAN 자동화](openwrt-router.md)를
따른다. 이 단계는 `br-ex`가 생기기 전인 지금 실행해야 한다.

## 6. cloud01 OpenStack 스토리지 준비

먼저 점검 모드로 대상과 시리얼을 확인한다.

```bash
sudo ./scripts/prepare-openstack-storage.sh
```

출력과 물리 라벨이 일치할 때만 정확한 확인 문자열로 적용한다.

```bash
export OPENSTACK_STORAGE_CONFIRM='WIPE-OPENSTACK-STORAGE:<출력된 데이터 SSD 시리얼>:<출력된 고속 NVMe 시리얼>'
sudo --preserve-env=OPENSTACK_STORAGE_CONFIRM ./scripts/prepare-openstack-storage.sh --apply
sudo reboot
```

이 단계는 1TB SSD와 2TB NVMe의 기존 파티션을 지운다. 스크립트가 dry-run에서 출력한 실제
확인 문자열을 그대로 사용한다. 스크립트는 로컬 plan의 cloud01 시리얼만 허용하며 새 물리
노드의 스토리지 준비에는 사용할 수 없다.

재부팅 후 호스트 사전 검사를 실행한다.

```bash
findmnt /var/lib/docker
sudo vgs cinder-ssd cinder-nvme
df -h / /var/log /var/lib/docker
./scripts/cluster.sh verify-hosts
```

`verify-hosts`는 호스트명, NIC, 시간 동기화, 이름 해석, 별도 `/var/lib/docker` 마운트와
cloud01의 두 Cinder VG를 검사한다.

## 7. 단일 노드 OpenStack 배포

최초 배포는 bootstrap과 deploy를 분리해 실행하는 cluster 명령을 사용한다.
`cloud02`나 `cloud03`처럼 SSH로 연결하는 노드가 토폴로지에 포함되면 root로 실행되는 Kolla
Ansible은 root의 SSH trust context를 사용한다. 배포 전에 검토한 지문을
`/root/.ssh/known_hosts`에 등록하거나
`ANSIBLE_SSH_COMMON_ARGS='-o UserKnownHostsFile=/home/operator/.ssh/known_hosts'`로 검토한
파일을 명시하고 `sudo --preserve-env=ANSIBLE_SSH_COMMON_ARGS`로 전달한다. 이 요구는
`deploy-openstack`, `expand-openstack`, `platform-apply`, `platform-reconfigure`에 동일하게
적용되며 host key 검사를 끄지 않는다. 최초 `cloud01`의 local connection에는 원격 host key가
없다.

```bash
sudo ./scripts/cluster.sh deploy-openstack
sudo ./scripts/openstack.sh cloud-init
sudo ./scripts/cluster.sh verify-openstack
```

`deploy-openstack`은 다음 순서를 실행한다.

1. 토폴로지 렌더링과 호스트 사전 검사
2. `kolla-ansible bootstrap-servers`
3. 전체 호스트 사실 수집
4. Kolla precheck와 이미지 pull
5. OpenStack deploy와 post-deploy
6. 생성된 서비스 설정 검증
7. 컨테이너 상태 검사

`verify-openstack`은 관리자 토큰 발급, 토폴로지의 각 Nova 컴퓨트 서비스와 하이퍼바이저,
네트워크 에이전트, Cinder 서비스와 Skyline HTTP 응답을 확인한다. Skyline 주소는
`http://192.0.2.10:9999`이다. Horizon은 배포하지 않는다.

## 8. Terraform으로 최초 Kubernetes VM 만들기

Terraform 실제 변수 파일에 SSH 공개키를 넣고, 생성될 네트워크·볼륨·VM을 검토한다.

```bash
umask 077
test -e terraform/openstack/terraform.tfvars || \
  cp terraform/openstack/terraform.tfvars.example terraform/openstack/terraform.tfvars
chmod 0600 terraform/openstack/terraform.tfvars
```

먼저 실제 공개키를 넣고 `enable_resources = false` 상태의 무변경 계획으로 인증과 provider
초기화를 확인한다. 일반 사용자 계정이
`/etc/kolla/clouds.yaml`을 읽을 수 없다면 Git에서 제외된 로컬 경로로 복사한다.

```bash
sudo install -m 0600 -o operator /etc/kolla/clouds.yaml terraform/openstack/clouds.yaml
export OS_CLIENT_CONFIG_FILE="$PWD/terraform/openstack/clouds.yaml"
./scripts/cluster.sh terraform-plan
./.cache/terraform/bin/terraform show .cache/cluster/kubernetes.tfplan
```

그 다음 `terraform.tfvars`에서 `enable_resources = true`로 바꾸고 계획을 다시 저장해 검토한다.

```bash
./scripts/cluster.sh terraform-plan
./.cache/terraform/bin/terraform show .cache/cluster/kubernetes.tfplan
```

저장된 계획에서 다음 항목을 확인한다.

- 외부망 `198.51.100.0/24`와 tenant 망 `203.0.113.0/24`
- tenant router의 고정 provider 주소 `198.51.100.2`
- Neutron unbound port로 예약되고 일반 할당에서 제외된 Kubernetes 내부 API VIP `203.0.113.10`
- `fast`, `standard` 볼륨 유형
- 최초 노드 `k8s-01` 한 대와 120GiB 부팅 볼륨
- 보안 그룹과 Floating IP `198.51.100.50`

검토한 같은 계획만 적용한다.

```bash
export TERRAFORM_APPLY_CONFIRM=APPLY-KUBERNETES-INFRA
./scripts/cluster.sh terraform-apply
```

## 9. 최초 management/hosting Kubernetes 클러스터

```bash
./scripts/cluster.sh deploy-kubernetes
```

Kubespray는 Terraform 출력으로 인벤토리를 만들고 `k8s-01`에 Kubernetes를 설치한다.
내부 API VIP는 `203.0.113.10`이며 kube-vip가 tenant 망에서 ARP로 광고한다. kubeadm의
control-plane endpoint도 이 VIP의 `6443` 포트로 고정하고, 관리용 kubeconfig는
`kubeconfig/admin.conf`에 저장한다.

이 클러스터는 애플리케이션을 모두 수용하는 영구적인 유일 클러스터가 아니다. 앞으로
Cluster API controller와 플랫폼 서비스를 실행할 최초 management/hosting cluster다. 현재
한 물리 노드 단계에서는 핵심 OpenStack과 이 부트스트랩 클러스터까지만 구성한다.

운영용 플랫폼 서비스는 다음 조건을 모두 충족한 뒤 별도 변경으로 켠다.

- OpenStack control·network·compute가 `cloud01`~`cloud03`에서 검증됨
- Ceph 데이터 HA와 Cinder·Glance 복원 시험이 완료됨
- management/hosting cluster도 3노드 배치, 백업과 복구 절차를 가짐

그 뒤 CAPI와 OpenStack 인프라 공급자인 CAPO를 management cluster에 설치한다. CAPI가
Kubernetes 클러스터 생명주기를 선언하고 CAPO가 OpenStack VM·네트워크·볼륨을 만든다.
Magnum API를 EKS와 유사한 사용자 진입점으로 제공할 때는 Kolla 2026.2 Magnum 이미지에
포함된 VEXXHOST `magnum-cluster-api` driver와 CAPO를 사용한다. 자동화는 이미지의
`k8s_cluster_api` driver가 비활성화되지 않았는지 검사한다. Magnum의 기존 Heat driver는
2026.2에서 제거되었다.
Kubernetes `LoadBalancer`에는 최초 배포부터 사용한 OVN과 맞는 Octavia OVN provider를
활성화한다. Amphora image·certificate 기반 구성은 이 목표 구조에 포함하지 않는다.

ECS와 유사한 컨테이너 서비스는 Kubernetes workload를 조정하는 별도 container-runtime
API를 자체 포털 뒤에 둔다. 현재 Kolla-Ansible 2026.2에서는 Zun과 Kuryr의 배포 지원이
2026.1부터 제거되었으므로 `enable_zun` 또는 `enable_kuryr`를 설정하지 않는다. Zun이 꼭
필요한 경우에만 OpenStack 2025.2 legacy 프로필을 별도 수명주기 결정으로 검토한다.

Ceph와 management cluster 복구가 검증된 뒤에는 k0smotron v2.3.0 Hosted Control Plane을
선택적으로 도입할 수 있다. k0smotron은 tenant control plane을 hosting cluster의 Pod로
실행하는 별도 control-plane provider이며 OpenStack, Magnum, CAPI 또는 CAPO의 내장 기능이
아니다.

단계별 목표는 다음과 같다.

1. `cloud01`: Skyline/OpenStack API와 핵심 서비스, Kubespray management/hosting cluster
2. `cloud01`~`cloud03`: OpenStack 제어·네트워크·컴퓨트 확장과 운영 검증
3. Ceph: 데이터 이전과 실제 복원 시험, management cluster의 3노드화
4. CAPI + CAPO + Magnum CAPI driver: OpenStack VM 기반 workload cluster 서비스
5. 자체 포털: OpenStack API와 Kubernetes 기반 container-runtime API를 하나의 진입점으로 제공
6. 필요할 때 k0smotron v2.3.0: Hosted Control Plane 추가

현재 저장소는 1·2단계와 3단계의 Ceph 준비 및 Kubernetes scale 기반을 제공한다. Ceph 데이터
이전과 복원 판정은 수동이다. 4단계의 ORC·CAPI·CAPO와 OpenStack Magnum·Octavia 기반은
`platform-services.sh`가 구성한다. 호환되는 Glance workload image와 Magnum cluster template
준비 및 첫 cluster의 전체 lifecycle 검증은 후속 작업이다.
참고 문서는 [Cluster API](https://main.cluster-api.sigs.k8s.io/),
[CAPO](https://cluster-api-openstack.sigs.k8s.io/),
[VEXXHOST Magnum Cluster API driver](https://vexxhost.github.io/magnum-cluster-api/),
[Magnum Cluster API 시작 안내](https://vexxhost.github.io/magnum-cluster-api/user/getting-started/),
[Magnum workload image](https://vexxhost.github.io/magnum-cluster-api/user/images/),
[CAPO Hosted Control Plane](https://cluster-api-openstack.sigs.k8s.io/topics/hosted-control-plane),
[k0smotron v2.3.0](https://docs.k0smotron.io/v2.3.0/install/),
[Kolla-Ansible 2026.1 릴리스 노트](https://docs.openstack.org/releasenotes/kolla-ansible/2026.1.html),
[Kolla-Ansible Neutron OVN](https://docs.openstack.org/kolla-ansible/latest/reference/networking/neutron.html),
[Octavia OVN provider](https://docs.openstack.org/kolla-ansible/latest/reference/networking/octavia.html)다.

## 10. 3노드와 Ceph 이후 Magnum/CAPI 기반 설치

[3노드 확장 절차](three-node-expansion.md)와 Ceph 데이터 이전·복구 시험을 끝낸 뒤 기본
`inventory/openstack-cluster.local.yml`을 최종 Ceph 토폴로지로 검토한다. 플랫폼 설정은
다음 상태에서 시작한다.

```yaml
cluster:
  storage_backend: ceph
  platform:
    magnum_capi:
      enabled: true
      hosted_control_plane: false
    container_service:
      enabled: false
      provider: kubernetes
  ceph:
    enabled: true
    openstack_pool_device_class: nvme
```

`container_service.enabled`는 후속 container-runtime API가 구현될 때까지 `false`로 둔다.
토폴로지를 다시 렌더링한다.

```bash
./scripts/cluster.sh render
```

`terraform/openstack/terraform.tfvars`의 `kubernetes_nodes`를 `k8s-01`~`k8s-03` control
plane·etcd·worker 세 대로 만든다. 이미 존재하는 `k8s-01`의 `volume_type = "fast"`는
유지하고 새 `k8s-02`, `k8s-03`만 `volume_type = "ceph"`로 설정한다. strict anti-affinity
배치와 계획을 검토한 뒤 적용한다. `management_api_address`는 위 topology의
`cluster.api_vip`와 같게 둔다. `kubernetes_api_host_number`는 tenant network 안의 내부
kube-vip를 별도로 선택한다.

```bash
export OS_CLIENT_CONFIG_FILE="$PWD/terraform/openstack/clouds.yaml"
./scripts/cluster.sh terraform-plan
export TERRAFORM_APPLY_CONFIRM=APPLY-KUBERNETES-INFRA
./scripts/cluster.sh terraform-apply
```

기존 `k8s-01`을 `ceph`로 바꾸면 boot volume 교체가 필요하지만 Terraform의
`prevent_destroy`가 이를 차단한다. 해당 노드의 Ceph 이전은 Cinder/VM 백업·복원 또는
검토된 migration을 별도 유지보수 작업으로 수행한 뒤 state와 변수를 맞춘다. 이 저장소는
그 이전을 자동화하지 않는다.

Kubernetes를 확장하기 전에 management cluster가 사용할 전용 non-admin `member` 사용자와
restricted OpenStack application credential을 한 번 만든다. 첫 실행은 정확한 확인 문자열을
출력할 뿐 원격 자원을 만들지 않는다.

```bash
./scripts/cluster.sh prepare-k8s-cloud
export MANAGEMENT_CLOUD_CONFIRM='CREATE-K8S-CLOUD-PRINCIPAL:<project-id>:kubespray-management:member'
./scripts/cluster.sh prepare-k8s-cloud
```

두 번째 명령에는 첫 실행이 출력한 실제 프로젝트 ID를 사용한다. 임의의 사용자 비밀번호는
application credential 발급 뒤 폐기한다. secret은 화면에 출력되지 않고
`kubeconfig/openstack-management.env`에 mode `0600`으로
저장된다. 같은 이름의 credential이나 로컬 파일이 이미 있으면 덮어쓰거나 회전하지 않고
중단한다. 이 파일을 외부 secret backup에 포함한 뒤 Kubernetes를 세 control plane으로
확장한다.

```bash
export KUBERNETES_CONTROL_PLANE_SCALE_CONFIRM='SCALE-KUBERNETES-CONTROL:k8s-02,k8s-03'
./scripts/cluster.sh deploy-kubernetes
```

실제 변경 대상이 다르면 스크립트가 출력한 확인값을 사용한다. Magnum 플래그가 켜진
토폴로지에서는 Kubespray renderer가 external OpenStack CCM, Cinder CSI controller 3개,
기본 `cinder-csi` StorageClass의 `ceph` volume type과 Octavia OVN LoadBalancer 변수를
자동 생성한다.

management Kubernetes 확장 후 플랫폼 plan을 실행한다. 이 검사는 세 물리 노드, 세
호스트의 `up/in` OSD와 Ceph `HEALTH_OK`, OVN 전용 Octavia 설정, Ready control plane 세 대와
동적 default StorageClass 하나를 요구한다.

```bash
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG ./scripts/cluster.sh platform-plan
```

현재 pin으로 `platform-plan`이 출력하는 최초 배포 확인값은 다음과 같다.

```bash
export PLATFORM_SERVICES_CONFIRM='APPLY-MAGNUM-CAPI:v1.14.3:v1.14.3:v0.15.1:v2.6.0'
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,PLATFORM_SERVICES_CONFIRM \
  ./scripts/cluster.sh platform-apply
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG ./scripts/cluster.sh platform-status
```

`apply`는 ORC v2.6.0, CAPI와 clusterctl v1.14.3, CAPO v0.15.1을 management cluster에
설치하고 `magnum-system`에 장기 ServiceAccount token을 만든다. mode `0600` kubeconfig는
`kolla/generated/magnum/kubeconfig`에 생성되고 Kolla가
`/etc/kolla/config/magnum/kubeconfig`에 설치한다. 이어서 Magnum, Barbican과 Octavia OVN
provider를 배포하고 endpoint와 provider를 검사한다. 두 kubeconfig 경로는 cluster-admin
credential이므로 백업과 접근 권한을 제한한다.

Kolla HAProxy는 `cluster.api_vip:6443`에서 세 control-plane Floating IP로 전달한다. Kubespray
API 인증서와 Magnum kubeconfig는 이 HA 주소를 사용한다. 복구를 위해
`state/kubespray/openstack/applied-nodes.json`, `kubeconfig/admin.conf`,
`kolla/generated/magnum/kubeconfig`, `kubeconfig/openstack-management.env`를 암호화된 외부
저장소에 함께 백업한다. 관리형 프로필을 활성화한 뒤 일반 `deploy-openstack`과
`expand-openstack`은 차단된다.

이미 배포한 플랫폼을 조정할 때는 `plan`이 출력하는
`RECONFIGURE-MAGNUM-CAPI:v1.14.3:v1.14.3:v0.15.1:v2.6.0` 확인값과
`cluster.sh platform-reconfigure`를 사용한다. `platform-status`는 controller
deployment·CRD, Magnum credential, OpenStack endpoint와 Octavia OVN provider를 읽어
검증한다. 제거 명령은 제공하지 않는다.

호환되는 workload image의 Glance 등록, Magnum cluster template 생성과 첫 cluster의
생성·접속·확장·업그레이드·삭제 lifecycle 검증, Kubernetes 기반 container-runtime API와
자체 포털은 후속 작업이다. 자세한 경계는 [managed services 문서](managed-services.md)를
따른다.

## 11. k0smotron Hosted Control Plane scaffold

Hosted Control Plane을 검토할 때만 `magnum_capi.hosted_control_plane: true`로 바꾸고 다시
렌더링한다. 검토한 k0s 버전을 명시해 scaffold를 만든다.

```bash
export HOSTED_K0S_VERSION='<검토한-k0s-version>'
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,HOSTED_K0S_VERSION \
  ./scripts/cluster.sh hosted-plan
```

결과는 `.cache/platform/k0smotron-<cluster-name>.yml`에 생성된다. 이 명령은 k0smotron
v2.3.0 provider를 설치하거나 manifest를 적용하지 않는다. template의 API 호환성,
OpenStack infrastructure reference, etcd PVC·LoadBalancer, 백업과 workload 수명주기를
검토한 뒤 별도 apply workflow를 설계한다.

## 12. 이후 확장

물리 서버 `cloud02`, `cloud03` 추가는 [3노드 확장 문서](three-node-expansion.md)를 따른다.
Kubernetes 노드 수와 역할은 `terraform/openstack/terraform.tfvars`의
`kubernetes_nodes`에서 관리한다. Control plane이나 etcd 역할 추가에는
`KUBERNETES_CONTROL_PLANE_SCALE_CONFIRM` 확인 문자열이 별도로 필요하다.

Ceph OSD 구성과 LVM 데이터 이전은 OpenStack 노드 확장과 함께 실행하지 않는다. 관련 안전
경계는 [자동화 안전 경계](automation-boundaries.md)에 정리되어 있다.

# 자동화 범위와 승인 지점

이 저장소는 새 3노드 Ceph/OpenStack 구축을 기준으로 한다. 각 파괴적 작업은 바로 앞의
읽기 전용 plan이 출력한 확인값을 요구한다.

| 단계 | 자동화 | 변경 범위 | 승인값 |
| --- | --- | --- | --- |
| Ubuntu seed | 노드별 autoinstall 렌더 | 일치하는 OS 디스크 | 설치 화면에서 시리얼 확인 |
| OpenWrt | discovery, UCI plan, rollback guard | 관리망·Provider VLAN | plan이 출력한 apply/confirm 값 |
| Kolla data | cloud01 1TB SSD 포맷 | `/var/lib/docker` | `WIPE-OPENSTACK-DATA:...` |
| Ceph bootstrap | MON/MGR cluster 생성 | `/etc/ceph`, cephadm 상태 | `BOOTSTRAP-CEPH:...` |
| Ceph host | MON/MGR host 등록 | 세 Ceph host | `ADD-CEPH-HOSTS:...` |
| Ceph OSD | 빈 디스크 세 개 OSD 생성 | manifest의 by-id만 | `WIPE-CEPH-OSDS:<sha>` |
| Ceph pool | RBD pool과 CRUSH rule | `images`, `volumes`, `vms` | `CONFIGURE-CEPH-POOLS:...` |
| Kolla client | 최소권한 Ceph keyring | ignored generated config | `EXPORT-KOLLA-CEPH-CLIENTS` |
| OpenStack | fresh multinode deploy | 세 host의 Kolla container | root 실행과 사전조건 |
| Terraform | network, volume, VM 3대 | 저장된 tfplan | `APPLY-KUBERNETES-INFRA` |
| Workload | 독립 VM stack | 저장된 stack tfplan | plan SHA-256 확인값 |

## Ubuntu와 디스크

Autoinstall은 topology의 노드별 `os_disk_serial`을 사용한다. 같은 seed를 다른 노드에 재사용하지
않는다. OS 디스크 이외의 Ceph OSD와 HDD는 Autoinstall storage config에 포함하지 않는다.

`prepare-openstack-storage.sh`는 `cloud01`의 1TB SSD 전체를 ext4로 만들어
`/var/lib/docker`에 마운트한다. 다음 장치는 명시적으로 보존한다.

- 128GB OS SSD
- Ceph용 2TB NVMe
- 512GB 여분 SSD
- 4TB와 3TB HDD

공개 예시 시리얼이나 정확하지 않은 확인값으로는 apply가 실행되지 않는다.

## Ceph

Ceph 자동화는 세 host와 빈 cluster의 최초 OSD 배포까지만 담당한다. 다음은 자동화 범위 밖이다.

- 운영 cluster의 OSD 추가·교체·제거
- SATA SSD/HDD class용 추가 pool과 Cinder type
- pool size나 CRUSH failure domain 변경
- 손실된 OSD의 강제 purge
- 재구축 또는 disaster recovery

`osd-plan`과 `osd-apply`는 기존 OSD가 하나라도 있으면 중단한다. OSD를 새로 추가할 때 이
guard를 제거하지 말고 별도 증설 workflow를 만든다.

## OpenStack

`deploy-openstack`은 다음 조건을 강제한다.

- 활성 물리 노드가 세 대 이상
- `storage_backend: ceph`
- 세 controller와 세 network node
- Ceph client config와 keyring export 완료
- host 검증 통과

단일 노드 deploy와 LVM-to-Ceph migration은 제공하지 않는다. `expand-openstack`은 이미
검증된 3노드 cloud에 네 번째 이후 host를 추가할 때만 사용한다.

## Terraform과 Kubernetes

기본 Terraform root는 세 management Kubernetes VM을 동시에 선언한다. 세 root volume은
모두 Ceph를 사용하며 control-plane server group은 strict anti-affinity다. tfplan을 새로
만들거나 입력이 바뀌면 이전 확인은 무효다.

애플리케이션 VM은 `terraform/workloads/<stack>`별 독립 state로 관리한다. 공통 module은 root
volume과 instance에 `prevent_destroy`를 설정한다. 교체가 필요한 변경은 먼저 백업과 새
인스턴스 이행 계획을 세운다.

## cloud01 고정 HBA VM

4TB·3TB HDD용 storage VM은 3노드 OpenStack 검증 이후에만 만든다. 자동화 경계는 다음과 같다.

1. 운영자가 실제 HBA PCI 주소와 IOMMU group을 확인한다.
2. ignored Nova config에 exact address, vendor/product ID와 `storage-hba` alias를 기록한다.
3. Kolla reconfigure 후 Nova가 HBA를 inventory로 보고하는지 확인한다.
4. Terraform이 cloud01 aggregate, 전용 flavor와 storage VM을 생성한다.

HBA가 연결된 `cloud01`에만 배치되며 live migration이나 HA 대상이 아니다. OS 디스크와 같은
SATA controller를 넘기지 않는다. 자세한 내용은 [스토리지 VM](storage-vm.md)을 따른다.

## 비밀과 상태

실제 MAC, IP, 디스크 시리얼, SSH 키, Ceph keyring, Kolla passwords, clouds.yaml, Terraform
state와 kubeconfig는 공개 저장소에 넣지 않는다. 파일 목록과 백업 기준은
[로컬 설정·비밀·상태](local-secrets-and-state.md)에 있다.

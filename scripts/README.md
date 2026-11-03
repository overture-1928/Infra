# 스크립트 구성

이 디렉터리의 루트에는 운영자가 직접 실행하는 명령만 둔다.
일반적인 설치와 확장 작업은 `cluster.sh`에서 시작하고, 단계별 확인이나 명시적인
승인이 필요한 작업만 개별 진입점을 사용한다.

| 파일 | 역할 |
| --- | --- |
| `cluster.sh` | 전체 설치, 검증, 확장과 workload 작업의 기본 진입점 |
| `ceph-cluster.sh` | Ceph bootstrap, OSD, pool과 Kolla client 관리 |
| `openstack.sh` | Kolla-Ansible 실행과 OpenStack 운영 명령 |
| `render-ubuntu-autoinstall.sh` | 노드별 Ubuntu autoinstall 설정 생성 |
| `build-autoinstall-seed.sh` | 생성한 설정으로 seed ISO 작성 |
| `inspect-openstack-storage.sh` | 디스크 식별자와 상태를 읽기 전용으로 점검 |
| `prepare-openstack-storage.sh` | cloud01의 Kolla 데이터 SSD 준비 |

`internal/`은 위 진입점이 호출하는 렌더러, 도구 설치기와 하위 실행기다. 런북에서
별도로 지시하지 않는 한 직접 실행하지 않는다.

Ceph의 최초 OSD는 `ceph-cluster.sh osd-plan/osd-apply`, 운영 중 균형 증설은
`osd-expand-plan/osd-expand-apply/osd-expand-status`로 분리한다. 증설 명령은
`inventory/ceph-osd-expansion.local.yml`의 FSID, 기존 OSD 수와 장치 manifest를 고정하며
교체·제거 또는 새 Cinder backend를 수행하지 않는다.

일반 VM은 `cluster.sh workload-new/plan/show/apply`로 관리하고, guest 구성은
`cluster.sh workload-inventory/configure`로 실행한다. 상황별 명령 선택은
[상황별 운영 가이드](../docs/operations/scenarios.md)를 따른다.

# 운영과 복구

이 디렉터리는 최초 구축의 구성요소별 상세 절차와 구축 후 운영 상황을 다룬다.

## 진입점과 보호

| 문서 | 용도 |
| --- | --- |
| [상황별 운영 가이드](scenarios.md) | 설치 재개, 장애, 설정 변경, state 복구와 확장 경로 선택 |
| [로컬 데이터와 복구](local-data-and-recovery.md) | ignored 입력, credential, state와 암호화 백업 대상 |
| [백업과 복원](backup-and-restore.md) | 로컬 상태, Kolla DB, Ceph/Kubernetes 설정의 복구 세트와 복원 검증 |
| [홈랩 보안](security.md) | 본인 SSH key, 운영 PC·백업 매체 분실과 credential 노출 대응 |

## 구성요소 운영

| 문서 | 용도 |
| --- | --- |
| [OpenWrt 운영](openwrt.md) | discovery, VLAN plan, rollback guard와 연결 검증 |
| [Ceph 최초 구축](ceph-initial-deployment.md) | 빈 cluster bootstrap, 최초 OSD, pool과 Kolla client |
| [OpenStack 일상 운영](openstack-day2.md) | API, quota, scheduler, network와 volume의 읽기 중심 진단 |
| [Masakari VM 복구](masakari.md) | Instance Monitor 적용 범위와 fencing 이후 Host Monitor 활성화 조건 |
| [Management Kubernetes 운영](kubernetes-day2.md) | node, PVC, LoadBalancer, cloud integration과 scale 진단 |
| [관측과 알림](observability.md) | Ceph, OpenStack, host, 디스크와 Kubernetes 상태·경보 기준 |

## 변경과 검증

| 문서 | 용도 |
| --- | --- |
| [장애 훈련](failure-drills.md) | host, OSD, Ceph network, API와 Kubernetes 장애 시험 |
| [물리 노드 확장](cluster-expansion.md) | cloud04 이후 compute 추가와 Ceph 증설 경계 |
| [Ceph 운영 변경](ceph-day2.md) | 운영 OSD 균형 증설 자동화, 교체·제거와 새 device class 검토 기준 |
| [업그레이드와 유지보수](upgrades.md) | Ubuntu, Ceph, Kolla, Terraform, Kubernetes 버전 변경 경계 |

운영 Ceph OSD 추가는 명시적인 change 파일과 plan/apply/status guard로 지원한다. OSD 교체·제거,
새 class의 pool/Cinder backend, controller role 제거, release upgrade와 자동 state 복구는 현재
apply 자동화 범위에 포함되지 않는다. [자동화 경계](../architecture/automation-boundaries.md)에서
차단 범위를 먼저 확인한다.

[전체 문서로 돌아가기](../README.md)

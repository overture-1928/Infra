# 운영과 복구

이 디렉터리는 최초 구축의 구성요소별 상세 절차와 구축 후 운영 상황을 다룬다.

| 문서 | 용도 |
| --- | --- |
| [상황별 운영 가이드](scenarios.md) | 설치 재개, 장애, 설정 변경, state 복구와 확장 경로 선택 |
| [로컬 데이터와 복구](local-data-and-recovery.md) | ignored 입력, credential, state와 암호화 백업 |
| [OpenWrt 운영](openwrt.md) | discovery, VLAN plan, rollback guard와 연결 검증 |
| [Ceph 최초 구축](ceph-initial-deployment.md) | 빈 cluster bootstrap, 최초 OSD, pool과 Kolla client |
| [물리 노드 확장](cluster-expansion.md) | cloud04 이후 compute 추가와 Ceph 증설 경계 |

운영 Ceph OSD 추가·교체·제거, controller role 제거와 자동 state 복구는 현재 자동화 범위에
포함되지 않는다. [자동화 경계](../architecture/automation-boundaries.md)에서 차단 범위를 먼저
확인한다.

[전체 문서로 돌아가기](../README.md)

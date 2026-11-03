# 아키텍처와 자동화 경계

이 디렉터리는 실제 설정값을 정할 때 필요한 설계 근거와 자동화의 안전 범위를 설명한다.

| 문서 | 답하는 질문 |
| --- | --- |
| [네트워크 설계](networking.md) | 관리, Provider VLAN, Ceph 10Gbps와 tenant 망을 어떻게 분리하는가? |
| [자동화 경계](automation-boundaries.md) | 어떤 단계가 자동화됐고 어떤 작업은 별도 검토가 필요한가? |
| [현재 한계와 운영 전 검토](current-limitations.md) | 물리 장애, 디스크 class, state와 관측에서 무엇이 아직 보장되지 않는가? |

실제 설치 명령은 [3노드 설치 런북](../getting-started/installation.md), 장애와 변경 상황은
[상황별 운영 가이드](../operations/scenarios.md)를 따른다.

[전체 문서로 돌아가기](../README.md)

# 내부 스크립트

이 디렉터리는 공개 실행 인터페이스가 아니다. 파일은 다음 역할로 나뉜다.

- `render-*`: topology에서 Kolla, Kubespray와 OpenWrt 입력을 생성한다.
- `setup-*`: 저장소에 고정된 버전의 Terraform, Kubespray와 cephadm을 준비한다.
- `openwrt-router.sh`, `platform-services.sh`, `terraform-workload.sh`: `cluster.sh`의 하위 명령을 구현한다.
- `deploy-openstack-kubernetes.sh`, `management-kubernetes-cloud.sh`: management Kubernetes 배포와 인증을 처리한다.
- `verify-openstack-cluster.sh`: 배포된 OpenStack의 필수 자원을 확인한다.
- `check-openstack-repository.sh`: 저장소 구조와 안전장치의 회귀 검사를 수행한다.

경로를 변경할 때는 루트 진입점, `Makefile`, 문서와 저장소 검사를 함께 수정한다.

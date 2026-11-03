# Ansible playbook 구성

- `openstack/`: Ubuntu 호스트, Ceph 장치와 management Kubernetes 노드 준비·검증
- `openwrt/`: 라우터 discovery, 적용, 연결 검증, 확인과 rollback
- `workloads/`: Terraform으로 만든 VM의 서비스별 guest 구성

일반적으로 playbook을 직접 실행하지 않고 `scripts/cluster.sh` 또는
`scripts/ceph-cluster.sh`를 사용한다. 두 진입점이 렌더링된 inventory와 필요한
확인 절차를 함께 적용한다. workload playbook은 `cluster.sh workload-configure <stack>`으로
실행하며 같은 이름의 Terraform output에서 inventory를 다시 만든다.

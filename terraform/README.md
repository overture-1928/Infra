# Terraform 디렉터리

이 디렉터리는 state의 소유권과 변경 범위에 따라 세 부분으로 나뉜다.

```text
terraform/
├── openstack/                  # management Kubernetes와 공용 기반 자원
├── modules/openstack-vm/       # 직접 apply하지 않는 공통 durable VM 모듈
└── workloads/
    ├── _template/              # 새 서비스 root 원본
    └── <stack>/                # 서비스별 코드, 변수와 독립 state
```

기존 `openstack/` root는 Kubespray와 platform 자동화가 출력과 state를 직접 사용하므로 이동하거나
일반 애플리케이션 VM을 섞지 않는다. 새 VM 묶음은 다음 명령으로 만든다.

```bash
./scripts/cluster.sh workload-new <stack>
```

같이 생성·백업·폐기하는 VM은 한 stack의 `instances` map에 둔다. 수명주기가 다르면 별도
stack을 사용한다. 각 stack의 `terraform.tfvars`와 `terraform.tfstate*`는 Git에서 제외되며
mode `0600`과 암호화 백업이 필요하다.

전체 생성, 자원 ID 입력, plan 검토와 적용 절차는
[서비스별 OpenStack VM Terraform 스택](../docs/terraform-workloads.md)을 따른다.

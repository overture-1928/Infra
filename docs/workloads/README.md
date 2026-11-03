# OpenStack workload

이 디렉터리는 기본 cloud 검증 이후 생성하는 VM과 guest 구성을 다룬다.

| 문서 | 용도 |
| --- | --- |
| [Terraform workload](terraform.md) | stack별 VM, volume, state와 자동 생성 Ansible inventory |
| [PCI 패스스루 VM](pci-passthrough.md) | cloud01 GPU 전용 VM, VFIO, Nova alias와 고정 배치 |
| [스토리지 VM](storage-vm.md) | 4TB·3TB HDD용 HBA 패스스루와 guest 디스크 구성 |

VM 생성은 Terraform, guest package와 서비스 설정은 Ansible playbook이 담당한다. PCI 장치를
사용하는 VM은 cloud01에 고정되며 live migration과 HA 대상이 아니다.

[전체 문서로 돌아가기](../README.md)

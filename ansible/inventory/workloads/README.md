# Workload inventory

`scripts/cluster.sh workload-inventory <stack>`은 Terraform의 `instances` output을 읽어
`.cache/ansible/workloads/<stack>.yml`을 생성한다. 실제 접속 설정은 이 디렉터리의
`<stack>.local.yml`에 두며 Git에는 포함하지 않는다.

새 설정은 `settings.example.yml`을 복사해 만들고 mode `0600`을 사용한다.

```bash
cp ansible/inventory/workloads/settings.example.yml \
  ansible/inventory/workloads/web.local.yml
chmod 0600 ansible/inventory/workloads/web.local.yml
```

`address_source`는 `auto`, `floating`, `fixed` 중 하나다. `auto`는 Floating IP가 있으면
우선 사용하고 없으면 정렬된 첫 번째 fixed IP를 사용한다. `host_vars`의 키는 workload의
Terraform `instances` map key와 같아야 한다.

3티어 profile의 output에는 `tier`가 포함되므로 renderer가 `workload_web`,
`workload_application`, `workload_database` 그룹을 추가한다. App·DB fixed IP로 직접 route가
없으면 `ansible_ssh_common_args`에 운영자가 검토한 SSH ProxyJump를 설정한다.

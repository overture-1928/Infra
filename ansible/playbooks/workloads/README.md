# Workload playbook

서비스별 playbook은 `<stack>.yml` 이름으로 저장하고 생성된 inventory의 `workload` 그룹을
대상으로 한다.

```yaml
---
- name: Configure web workload
  hosts: workload
  become: true
  gather_facts: true
  roles:
    - web
```

`scripts/cluster.sh workload-configure web`은 inventory를 다시 생성한 다음
`ansible/playbooks/workloads/web.yml`을 실행한다.

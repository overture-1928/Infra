# Magnum CAPI 관리형 서비스

> 문서 위치: [전체 문서](../README.md) · [관리형 플랫폼](README.md)

최초 3노드 OpenStack을 검증할 때까지 모든 관리형 서비스 플래그를 끈다.
`platform-services.sh`는 물리 노드 3대, 세 OSD 호스트의 정상 Ceph, Ready 상태인 management Kubernetes control plane 3대가
확인되기 전에는 Kubernetes와 OpenStack을 변경하지 않는다. Management cluster에는 동적
프로비저닝을 지원하는 비로컬 기본 StorageClass도 정확히 하나 있어야 한다.
Application credential, kubeconfig와 Terraform 상태의 보관·백업 기준은
[로컬 전용 설정, 인증정보와 운영 상태](../operations/local-data-and-recovery.md)를 따른다.

Management Kubernetes VM은 `HA_Enabled=True`와 `soft-anti-affinity`로 생성한다. Masakari는 이
VM의 process 장애를 먼저 복구하고, 물리 host evacuation은 fencing을 갖춘 이후 단계로 남긴다.
Workload cluster는 CAPI `MachineHealthCheck`도 사용할 수 있으므로 Masakari의 목표 복구 시간을
먼저 주고 그보다 긴 NotReady timeout에서 CAPI가 Machine을 교체하도록 구성한다. 세부 경계는
[Masakari VM 복구](../operations/masakari.md)를 따른다.

## Management Kubernetes 부트스트랩

Management Kubernetes는 CAPO가 만드는 대상이 아니다. Terraform이 OpenStack에 기반 VM과
네트워크를 먼저 만들고, Kubespray가 그 VM에 Kubernetes를 설치한다. 아래 그림의 실선은 현재
자동화된 경로이며, 파일 이름은 Git에서 제외해 로컬에 보관하는 인증·상태 파일이다.

```mermaid
flowchart TB
    operator["운영자 · cloud01의 저장소"]

    subgraph local["로컬 자동화와 보호 파일"]
        admincloud["admin clouds.yaml<br/>/etc/kolla 또는 terraform/openstack<br/>OpenStack 관리 작업용"]
        tf["Terraform<br/>terraform-plan / terraform-apply"]
        appbuilder["prepare-k8s-cloud<br/>전용 member 사용자와<br/>restricted application credential 생성"]
        appenv["kubeconfig/openstack-management.env<br/>mode 0600 · secret 출력 안 함"]
        kubespray["Kubespray<br/>deploy-kubernetes"]
        adminconf["kubeconfig/admin.conf<br/>management cluster 관리자 kubeconfig"]
        platform["platform-plan / platform-apply<br/>CAPI · CAPO · ORC 설치"]
    end

    subgraph osapi["OpenStack service catalog · 관리 API"]
        keystone["Keystone<br/>token · 사용자 · application credential"]
        computeapi["Nova · Neutron · Cinder · Glance"]
        octaviaapi["Octavia OVN<br/>LoadBalancer API"]
        barbicanapi["Barbican<br/>secret API"]
    end

    subgraph infra["Terraform이 만드는 management cluster 기반"]
        tnet["tenant network · subnet · security group"]
        cpvms["control-plane VM 3대<br/>boot volume · port"]
        fips["control-plane Floating IP 3개"]
    end

    subgraph management["Management Kubernetes"]
        apiservers["kube-apiserver 3대"]
        internalvip["tenant 내부 kube-vip<br/>VM과 cluster 내부용 :6443"]
        addons["external OpenStack CCM<br/>Cinder CSI · Octavia integration"]
        providers["CAPI core · kubeadm bootstrap/control-plane<br/>CAPO · ORC controllers"]
    end

    bootstrapfip["최초 control-plane FIP :6443<br/>Kubespray bootstrap와 admin.conf 접속점"]
    finalapi["Magnum이 접속할 최종 HA endpoint<br/>cluster.api_vip:6443"]
    haproxy["Kolla HAProxy listener<br/>backend = control-plane FIP 3개"]

    operator --> admincloud
    admincloud -->|"admin API 인증"| tf
    tf --> computeapi
    computeapi --> tnet
    computeapi --> cpvms
    computeapi --> fips

    admincloud -->|"현재 project와 domain 확인"| appbuilder
    appbuilder -->|"사용자 · role · credential"| keystone
    appbuilder --> appenv
    operator --> kubespray
    cpvms -->|"SSH 대상"| kubespray
    appenv -->|"OS_APPLICATION_CREDENTIAL_*"| kubespray
    kubespray --> apiservers
    kubespray --> addons
    kubespray --> adminconf
    kubespray --> internalvip

    fips --> bootstrapfip
    bootstrapfip --> apiservers
    tnet --> internalvip
    internalvip --> apiservers
    adminconf -->|"MANAGEMENT_KUBECONFIG"| platform
    platform --> providers
    platform --> haproxy
    platform -.->|"Kolla 서비스 배포"| octaviaapi
    platform -.->|"Kolla 서비스 배포"| barbicanapi
    finalapi --> haproxy
    haproxy --> fips
    appenv -->|"project 범위 OpenStack API"| addons
    addons --> computeapi
    addons --> octaviaapi
```

`kubeconfig/openstack-management.env`는 management cluster 안의 CCM·Cinder CSI·Octavia 연동이
OpenStack API를 호출할 때 쓰는 project 범위 application credential이다. 반면
`kubeconfig/admin.conf`는 `platform-services.sh`가 management Kubernetes API에 CAPI provider를
설치할 때 쓰는 Kubernetes 관리자 인증이다. 두 인증은 용도와 회전 절차가 다르다.

Kubespray 부트스트랩과 로컬 `admin.conf`는 첫 control-plane Floating IP를 사용한다. 플랫폼
적용 후 Kolla HAProxy가 `cluster.api_vip:6443`에서 세 control-plane Floating IP로 분산하고,
Magnum용 kubeconfig는 이 HA endpoint를 사용한다. Tenant 내부의 kube-vip는 management VM과
Pod가 같은 tenant network 안에서 API에 접근할 때 쓰는 별도 주소다.

## Magnum 요청과 CAPI 조정 루프

사용자의 요청은 Magnum에서 끝나지 않는다. `magnum-capi` driver가 management cluster에 원하는
상태를 기록하고, 여러 controller가 OpenStack의 실제 자원 상태를 계속 관찰하며 일치시킨다.

### 요청과 인증 경계

```mermaid
flowchart LR
    user["사용자 · 자체 포털<br/>OpenStack CLI/API"]
    keystone["Keystone<br/>project · role · quota"]

    subgraph magnumsvc["OpenStack control plane"]
        magapi["Magnum API"]
        conductor["Magnum conductor<br/>k8s_cluster_api / magnum-capi driver"]
        sakubeconfig["kolla/generated/magnum/kubeconfig<br/>→ /etc/kolla/config/magnum/kubeconfig<br/>ServiceAccount token · HA API :6443"]
        barbican["Barbican<br/>certificate · secret"]
    end

    subgraph mgmtapi["Management Kubernetes API · desired state 저장"]
        desired["CAPI 객체<br/>Cluster · KubeadmControlPlane · MachineDeployment<br/>OpenStackCluster · OpenStackMachineTemplate"]
        projectauth["workload project 범위<br/>OpenStack 인증 Secret / 참조"]
    end

    user -->|"cluster 생성 · 확장 · 삭제"| keystone
    keystone -->|"token"| magapi
    magapi --> conductor
    sakubeconfig -.->|"Kubernetes API 인증"| conductor
    conductor -->|"create · update · delete"| desired
    conductor --> projectauth
    conductor -->|"인증서·secret 처리"| barbican
```

### Controller가 OpenStack 자원을 만드는 경로

```mermaid
flowchart TB
    desired["Management API의 원하는 상태 CR"]
    projectauth["workload project 인증 Secret / 참조"]

    subgraph reconcilers["Management cluster의 지속 조정 controller"]
        direction LR
        capi["CAPI core<br/>Cluster · Machine lifecycle"]
        kubeadm["kubeadm providers<br/>bootstrap data · control plane"]
        capo["CAPO<br/>OpenStackCluster · OpenStackMachine"]
        orc["ORC<br/>OpenStack Server · Image CR"]
    end

    subgraph catalog["OpenStack API endpoints"]
        direction LR
        computenet["Nova · Neutron<br/>server · network · port · security group"]
        storageimage["Cinder/Ceph · Glance<br/>boot/data volume · Kubernetes image"]
        loadbalancer["Octavia OVN<br/>workload API LoadBalancer"]
    end

    subgraph workload["OpenStack tenant의 workload Kubernetes"]
        resources["VM · port · volume · image · load balancer"]
        controlplane["workload control plane"]
        workers["worker nodes"]
        workloadapi["workload Kubernetes API · Ready 상태"]
    end

    desired --> capi
    desired --> kubeadm
    desired --> capo
    projectauth --> capo
    projectauth --> orc
    capi <-->|"owner reference · phase"| kubeadm
    capi <-->|"Machine와 infrastructure 연결"| capo
    capo <-->|"Server · Image CR"| orc

    capo --> computenet
    capo --> storageimage
    capo --> loadbalancer
    orc --> computenet
    orc --> storageimage
    computenet --> resources
    storageimage --> resources
    loadbalancer --> resources
    resources --> controlplane
    resources --> workers
    controlplane --> workloadapi
    workers --> workloadapi
```

### 관찰과 상태 반환 루프

```mermaid
flowchart LR
    desired[("Management Kubernetes etcd<br/>desired CR + status")]
    reconcilers["CAPI · kubeadm · CAPO · ORC<br/>reconcile loop"]
    openstack["OpenStack 실제 상태<br/>VM · network · volume · image · LB"]
    workload["workload Kubernetes<br/>API · node health · replica"]
    condition["CAPI conditions<br/>Ready · replicas · failure reason"]
    conductor["Magnum conductor<br/>cluster 상태 변환"]
    magapi["Magnum API<br/>CREATE_IN_PROGRESS → COMPLETE/FAILED"]
    user["사용자<br/>같은 cluster UUID로 조회"]

    desired --> reconcilers
    reconcilers -->|"OpenStack API 호출"| openstack
    openstack -.->|"실제 자원 관찰"| reconcilers
    workload -.->|"health 관찰"| reconcilers
    reconcilers --> condition --> desired
    condition -.-> conductor -.-> magapi -.-> user
    restart["controller 재시작"] -.->|"desired state에서 재개"| reconcilers
```

실선은 생성·변경 명령과 자원 의존성이고, 점선은 실제 상태를 다시 읽어 Magnum까지 올리는
관찰 경로다. Controller가 중단됐다가 다시 시작되어도 management Kubernetes에 저장된 CR의
원하는 상태를 기준으로 조정을 재개한다. OpenStack API가 일시적으로 실패하면 CAPI condition과
Magnum 상태에 원인이 남으며, 사용자는 같은 cluster UUID를 통해 진행 상황을 확인한다.

요청 그림에는 세 인증 경계가 있다. 사용자의 Keystone token은 Magnum API 요청을 인증하고,
`magnum-capi` ServiceAccount kubeconfig는 Magnum conductor가 management Kubernetes API에
접속할 때 사용한다. Workload project의 OpenStack 인증 참조는 CAPO·ORC가 그 project에 VM과
네트워크를 조정하기 위한 것으로, management cluster 자체 CCM·CSI가 사용하는
`openstack-management.env`와는 별개다.

## 3노드 이후 활성화 순서

최초 3노드 Ceph/OpenStack과 management Kubernetes의 복구 시험까지 끝낸 뒤 로컬
topology에서 다음 값만 활성화한다.

```yaml
cluster:
  storage_backend: ceph
  platform:
    magnum_capi:
      enabled: true
      hosted_control_plane: false
    container_service:
      enabled: false
      provider: kubernetes
```

`container_service`는 아직 켜지 않는다. 이 플래그는 Magnum으로 만든 전용 runtime cluster와
별도 container API가 준비되는 후속 단계용이다. 현재 고정한 Kolla-Ansible 2026.2에는 Zun
배포 지원이 없으므로 provider는 계속 `kubernetes`를 사용한다.

토폴로지를 렌더링하고 Terraform 변수에 management control plane 세 대를 선언한다. 기존
`k8s-01`의 `standard` 부팅 볼륨 유형은 그대로 유지한다. 이를 `ceph`로 바꾸면 Terraform이 볼륨
교체를 계획하고 `prevent_destroy`가 적용을 막는다. 새 `k8s-02`, `k8s-03`만 `ceph`로 만들며,
기존 부팅 볼륨의 이전은 별도 유지보수 작업으로 처리한다.

`terraform/openstack/terraform.tfvars`의 `management_api_address`는 최종 Ceph topology의
`cluster.api_vip`와 같아야 한다. `kubernetes_api_host_number`는 tenant network 안의 내부
kube-vip 주소를 고른다. 두 주소는 용도가 다르다.

```bash
./scripts/cluster.sh render
./scripts/cluster.sh terraform-plan
export TERRAFORM_APPLY_CONFIRM=APPLY-KUBERNETES-INFRA
./scripts/cluster.sh terraform-apply
```

관리용 Kubernetes가 OpenStack API를 사용할 전용 non-admin `member` 사용자와 restricted
application credential을 한 번 만든다. 운영자가 읽을 수 있는 admin `clouds.yaml`을
지정해야 한다. 첫 실행은 프로젝트 ID가 포함된 정확한 확인 문자열을 출력하고 아무 사용자도
만들지 않는다.

```bash
export OS_CLIENT_CONFIG_FILE="$PWD/terraform/openstack/clouds.yaml"
export OS_CLOUD=admin
./scripts/cluster.sh prepare-k8s-cloud
# 위 명령이 출력한 값을 그대로 검토해 설정한다.
export MANAGEMENT_CLOUD_CONFIRM='CREATE-K8S-CLOUD-PRINCIPAL:<project-id>:kubespray-management:member'
./scripts/cluster.sh prepare-k8s-cloud
./scripts/cluster.sh deploy-kubernetes
```

임의로 만든 사용자 비밀번호는 application credential 발급 직후 폐기한다. application
credential secret은 화면에 출력하지 않고 Git에서 제외된
`kubeconfig/openstack-management.env`에 mode `0600`으로 저장한다. 자동화는 기존 사용자나
credential을 삭제·재설정·회전하지 않는다. 생성 도중 실패하면 이번 실행이 새로 만든 전용
사용자만 롤백한다. 롤백까지 실패하면 정확한 user ID와 domain ID를 출력하고 재실행을
거부하므로 운영자가 해당 원격 상태를 먼저 검토해야 한다. admin cloud의 `cacert`도 저장해
CCM과 Cinder CSI가 같은 CA를 사용한다.

Magnum 플래그가 활성화된 경우 Kubespray renderer는 external OpenStack CCM, controller 3개의
Cinder CSI, 기본 `ceph` StorageClass와 Octavia OVN 설정을 자동 생성한다. 기존 local-path
StorageClass는 남지만 기본값에서는 제외된다.

## Magnum, CAPI와 CAPO 적용

읽기 중심 사전 검사와 정확한 확인 문자열을 먼저 출력한다.

```bash
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,MANAGEMENT_KUBECONFIG \
  ./scripts/cluster.sh platform-plan
```

`MANAGEMENT_KUBECONFIG`를 지정하지 않으면 `kubeconfig/admin.conf`를 사용한다. 출력된 값을
검토한 뒤 최초 적용에서는 다음 형태로 실행한다.

`platform-apply`와 `platform-reconfigure`는 Kolla를 root로 실행한다. 원격 OpenStack 노드의
검토된 지문이 `/root/.ssh/known_hosts`에 준비되어 있어야 한다. 명시적인
`UserKnownHostsFile` 방식을 사용한다면 `ANSIBLE_SSH_COMMON_ARGS`도 해당 `sudo --preserve-env`
목록에 추가한다.

```bash
export PLATFORM_SERVICES_CONFIRM='APPLY-MAGNUM-CAPI:v1.14.3:v1.14.3:v0.15.1:v2.6.0'
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,PLATFORM_SERVICES_CONFIRM,MANAGEMENT_KUBECONFIG \
  ./scripts/cluster.sh platform-apply
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,MANAGEMENT_KUBECONFIG \
  ./scripts/cluster.sh platform-status
```

자동화는 고정 버전 ORC, CAPI core, kubeadm bootstrap/control-plane provider와 CAPO를 management
cluster에 설치한 뒤 Magnum, Barbican과 Octavia OVN provider를 Kolla로 배포한다. 재적용에는
`platform-reconfigure`와 plan이 출력한 `RECONFIGURE-MAGNUM-CAPI:...` 확인 문자열을 사용한다.
다운로드하는 `clusterctl`, ORC manifest와 Kubespray용 `kubectl`은 `config/versions.env`의
SHA-256과 일치해야 실행한다. 관리형 프로필을 켠 뒤에는 일반 `deploy-openstack`과
`expand-openstack`이 차단되므로 플랫폼 변경은 `platform-apply` 또는
`platform-reconfigure`로 수행한다.

Kolla 2026.2 Magnum 이미지에는 VEXXHOST `magnum-cluster-api` driver가 포함되어 있다. 자동화는
배포된 `magnum.conf`에서 `k8s_cluster_api` driver가 비활성화되지 않았는지 검사한다. 플랫폼
적용 후에는 호환되는 Kubernetes workload image를 Glance에 등록하고 Magnum cluster template을
만든 뒤, 첫 cluster의 생성·접속·확장·업그레이드·삭제 lifecycle을 검증한다.

### 첫 workload cluster 검증

관리형 플랫폼은 `platform-status`만 통과했다고 운영 준비가 끝난 것이 아니다. 첫 workload
cluster의 입력과 결과를 로컬 변경 기록에 남긴다.

| 입력 | 기록할 값 |
| --- | --- |
| image | Glance image ID, checksum, Kubernetes/kubeadm 호환 버전 |
| cluster template | driver, image, network, DNS, volume, master/worker flavor |
| project | project ID, quota, CAPO가 사용할 credential 참조 |
| topology | control plane/worker replica와 failure domain |
| network | tenant network/subnet, API LoadBalancer, Floating IP 사용 여부 |
| storage | root/data volume type과 Cinder CSI StorageClass |

생성 전 API와 provider 상태를 저장한다.

```bash
export OS_CLIENT_CONFIG_FILE="$PWD/terraform/openstack/clouds.yaml"
export OS_CLOUD=admin
.cache/kolla-venv/bin/openstack image list
.cache/kolla-venv/bin/openstack coe cluster template list
.cache/kolla-venv/bin/openstack coe cluster list
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,MANAGEMENT_KUBECONFIG \
  ./scripts/cluster.sh platform-status
```

cluster 생성 명령의 옵션은 설치된 `magnum-cluster-api` driver와 만든 template에 맞춰 검토한다.
예시 이름이나 외부 문서의 UUID를 그대로 복사하지 않는다. 생성 중에는 Magnum 상태만 보지 않고
management Kubernetes의 `Cluster`, `KubeadmControlPlane`, `Machine`, `OpenStackCluster` condition과
OpenStack server/port/volume/LoadBalancer를 함께 확인한다.

첫 cluster는 다음 lifecycle을 모두 통과해야 한다.

1. 생성 요청이 `CREATE_COMPLETE`에 도달하고 control plane과 worker Node가 Ready다.
2. workload kubeconfig로 API에 접속하고 Cinder PVC와 Octavia `LoadBalancer` Service를 생성·삭제한다.
3. worker를 한 대 늘리고 새 Node와 OpenStack server가 Ready가 된 뒤 다시 줄인다.
4. CAPO 또는 CAPI controller를 한 번 재시작해 기존 desired state에서 reconciliation을 재개한다.
5. 지원되는 Kubernetes patch/minor upgrade를 별도 plan으로 실행하고 workload가 유지되는지 본다.
6. cluster를 삭제하고 관련 server, port, volume, LoadBalancer, CAPI object와 credential 잔여물을
   확인한다.
7. 같은 template로 두 번째 cluster를 만들어 최초 성공이 우연한 수동 상태에 의존하지 않았음을
   확인한다.

각 단계의 시작·종료 시각, Magnum 상태, CAPI failure reason과 남은 OpenStack 자원을 기록한다.
생성만 성공하고 scale, delete 또는 orphan 검사가 실패하면 관리형 서비스는 아직 운영 준비가
끝난 것이 아니다.

Magnum용 `magnum-capi` ServiceAccount와 장기 token Secret은 `magnum-system`에 생성한다. 해당
cluster-admin kubeconfig는 `kolla/generated/magnum/kubeconfig`에 mode `0600`으로 저장되고,
Kolla가 `/etc/kolla/config/magnum/kubeconfig`로 복사한다. 두 파일은 관리 비밀로 취급한다.

Kolla는 `cluster.api_vip:6443`에 management Kubernetes API용 HAProxy listener를 만들고
Terraform의 세 control-plane Floating IP를 backend로 사용한다. Kubespray는 이 주소를 API
인증서 SAN에 넣으며 Magnum kubeconfig도 이 HA endpoint를 사용한다. 복구에 필요한
`state/kubespray/openstack/applied-nodes.json`, `kubeconfig/admin.conf`,
`kolla/generated/magnum/kubeconfig`, `kubeconfig/openstack-management.env`를 암호화된 외부
백업에 함께 보관한다.

## Hosted Control Plane과 컨테이너 API

`hosted-plan`은 `cluster.platform.magnum_capi.hosted_control_plane=true`일 때만 K0smotron
초안을 `.cache/platform/`에 만든다. 실제 K0smotron 설치나 리소스 적용은 하지 않는다.
Hosted control plane의 etcd 저장소, LoadBalancer endpoint, CAPO worker와 복구 절차를 검토한
후 별도 적용 자동화를 추가해야 한다.

```mermaid
flowchart TB
    subgraph current["현재 provider와 Magnum workload 경로"]
        capi["CAPI core · kubeadm providers<br/>CAPO · ORC"]
        kcp["KubeadmControlPlane"]
        cpvm["workload control-plane VM 3대<br/>OpenStack Nova"]
        md["MachineDeployment"]
        workervm["workload worker VM"]

        capi --> kcp
        kcp --> cpvm
        capi --> md
        md --> workervm
    end

    flag["hosted_control_plane: true"]
    plan["cluster.sh hosted-plan"]
    rendered[".cache/platform/k0smotron-*.yml<br/>Cluster + K0smotronControlPlane 초안"]
    boundary["자동화 경계<br/>여기서 중단 · kubectl apply 안 함"]

    subgraph future["향후 별도 설계·검증 후 가능한 구조"]
        operator["K0smotron operator<br/>현재 설치하지 않음"]
        hostedcp["management cluster 안의<br/>hosted control-plane Pod"]
        etcdpvc["etcd PVC<br/>비로컬 기본 StorageClass · Ceph"]
        apiLB["workload API Service<br/>Octavia OVN LoadBalancer"]
        futurecapi["CAPI · CAPO<br/>별도 worker manifest 필요"]
        capoworker["MachineDeployment<br/>OpenStack worker VM"]

        operator -.-> hostedcp
        hostedcp -.-> etcdpvc
        hostedcp -.-> apiLB
        futurecapi -.-> capoworker
    end

    flag -.-> plan
    plan -.-> rendered
    rendered -.-> boundary
    boundary -.->|"현재는 통과하지 않음"| operator
```

왼쪽 실선은 `platform-apply`가 provider를 준비한 뒤 Magnum 요청이 사용하는 일반 workload
경로다. 오른쪽 점선은 manifest 렌더링 뒤의 미래 설계다. K0smotron operator, hosted control
plane, PVC, LoadBalancer와 CAPO worker를 현재 자동화가 생성한다고 해석하면 안 된다. 특히
management cluster 장애가 workload control plane 장애로 이어지는 범위와 etcd PVC 복구를
먼저 검증해야 한다.

### 현재 apply를 차단하는 이유

현재 template에는 `Cluster`와 `K0smotronControlPlane`만 있다. K0smotron CRD와 controller를
설치하지 않으므로 그대로 apply하면 리소스 종류를 찾지 못해 실패한다. Operator를 수동으로
설치하더라도 OpenStack network와 worker를 만드는 CAPO 리소스가 없어 완전한 workload
Kubernetes가 되지 않는다.

| 누락 영역 | 추가해야 할 항목 | 없을 때 발생하는 결과 |
| --- | --- | --- |
| Provider 설치 | 고정 버전 K0smotron operator·CRD, artifact 무결성 검사, controller Ready 확인 | `K0smotronControlPlane`을 처리할 controller가 없음 |
| OpenStack 기반 | `OpenStackCluster`, project 범위 인증 Secret, network·subnet·security group 참조 | hosted API와 OpenStack worker가 같은 cluster로 연결되지 않음 |
| Worker | `MachineDeployment`, bootstrap config, `OpenStackMachineTemplate`, image·flavor | API만 있고 실행 node가 없는 cluster가 됨 |
| API endpoint | Octavia OVN LoadBalancer 도달성, 주소·port, 인증서 SAN 검증 | worker와 사용자가 API에 접속하지 못할 수 있음 |
| etcd 저장소 | Ceph-backed StorageClass 명시, PVC 배치·용량·snapshot·restore 기준 | control plane 상태 유실 또는 복구 불가 |
| 운영 자동화 | plan/apply/reconfigure/status와 승인값, 실패 시 재조정·정리 절차 | 부분 생성과 orphan 자원을 판별하거나 안전하게 복구하기 어려움 |
| Magnum 연동 | 일반 kubeadm driver와 hosted 방식의 template·status 변환 경계 | Magnum 상태와 실제 CAPI 상태가 다를 수 있음 |

### 구현 순서

Hosted Control Plane 적용 자동화는 다음 순서로 추가한다. 앞 단계가 검증되기 전에는 다음 단계의
apply 명령을 열지 않는다.

1. `config/versions.env`에 고정된 K0smotron 버전과 CAPI/CAPO/Kubernetes 호환 조합을 검토하고,
   다운로드 artifact의 checksum 또는 서명 검증 방식을 추가한다.
2. management Kubernetes에 CRD와 operator를 설치하고 deployment version, Available condition,
   필수 CRD를 `platform-status`와 같은 수준으로 검사한다.
3. project 범위 OpenStack credential, `OpenStackCluster`, hosted control plane, API Service를 하나의
   cluster manifest로 렌더링한다. secret 값은 `.cache` manifest나 Git 추적 파일에 평문으로
   기록하지 않는다.
4. CAPO `MachineDeployment`와 worker template을 연결하고 image, flavor, network, failure domain,
   replica를 로컬 입력으로 받는다.
5. 읽기 전용 plan과 exact confirmation을 거친 `hosted-apply`, 실제 CR·Pod·PVC·LoadBalancer·Node를
   읽어 검증하는 `hosted-status`를 구현한다.
6. upgrade, scale, controller 재시작, management node 장애, API LoadBalancer 장애, PVC snapshot과
   restore, cluster 삭제를 시험한다.
7. 일반 CAPI cluster와 Hosted Control Plane 중 어떤 방식이 Magnum cluster template에 대응하는지
   명시하고, Magnum 상태가 CAPI condition을 올바르게 반영하는지 확인한다.

```mermaid
flowchart LR
    VERSION["호환 버전·artifact 검증"] --> OPERATOR["K0smotron CRD·operator"]
    OPERATOR --> INFRA["OpenStackCluster·credential"]
    INFRA --> HCP["Hosted control plane·Ceph PVC·API LB"]
    HCP --> WORKER["CAPO MachineDeployment worker"]
    WORKER --> STATUS["hosted-status 정상"]
    STATUS --> LIFE["scale·upgrade·장애·restore·delete 시험"]
    LIFE --> MAGNUM["Magnum template와 status 연동"]
```

### apply 자동화 완료 기준

다음 조건을 모두 만족해야 `hosted-plan`의 future-only 제한을 제거할 수 있다.

- 새 cluster가 정해진 시간 안에 control plane Ready와 worker Node Ready에 도달한다.
- API endpoint가 management cluster 외부와 OpenStack tenant worker에서 모두 접근 가능하다.
- control plane replica, etcd PVC와 LoadBalancer가 선언한 수와 StorageClass를 사용한다.
- management controller를 재시작해도 기존 desired state에서 조정을 재개한다.
- worker scale-out/scale-in과 control plane/Kubernetes version upgrade 결과가 상태 검사에 반영된다.
- management node 한 대 장애 및 hosted control plane Pod 재생성 후 API와 etcd가 정상이다.
- 백업한 etcd/PVC 데이터로 별도 검증 환경에서 복원할 수 있다.
- cluster 삭제 후 OpenStack server, port, volume, LoadBalancer와 Kubernetes Secret/PVC가 정책대로
  정리되며, 보존 대상으로 선언한 backup은 남는다.
- 중간 실패 시 재실행으로 수렴하거나 문서화된 rollback/cleanup 경로가 있고 orphan 검사가
  통과한다.
- 위 결과를 실제 장비의 버전, 적용 Git commit, 입력 checksum과 함께 기록한다.

```bash
export HOSTED_K0S_VERSION='v1.36.0+k0s.0'
sudo --preserve-env=OPENSTACK_CLUSTER_CONFIG,HOSTED_K0S_VERSION,MANAGEMENT_KUBECONFIG \
  ./scripts/cluster.sh hosted-plan
```

ECS와 유사한 container API도 현재 단계에서는 배포하지 않는다. Magnum/CAPI workload cluster가
실제로 생성되고 격리·quota·이미지 정책이 정해진 뒤, 그 API가 전용 Kubernetes runtime
cluster의 Deployment, Job과 Service를 조정하도록 추가한다.

Driver와 workload 준비 절차는
[VEXXHOST Magnum Cluster API driver](https://vexxhost.github.io/magnum-cluster-api/),
[시작 안내](https://vexxhost.github.io/magnum-cluster-api/user/getting-started/),
[workload image 안내](https://vexxhost.github.io/magnum-cluster-api/user/images/)를 따른다.

# Ceph 운영 변경: 증설·교체·제거

> 문서 위치: [전체 문서](../README.md) · [운영과 복구](README.md)

최초 OSD 세 개는 [Ceph 최초 구축](ceph-initial-deployment.md)의 자동화로 만든다. 이 문서는
운영 중 capacity 확장과 장애 장치 교체를 준비하는 기준이다. 현재 `ceph-cluster.sh`는 운영
cluster에 OSD가 하나라도 있으면 `osd-plan/osd-apply`를 차단하므로, 아래 절차가 기존 명령의
guard를 우회하는 방법은 아니다.

## 변경 원칙

```mermaid
flowchart TB
  NEED{"왜 변경하는가?"}
  CAP["용량·성능 증설"]
  FAIL["장애 장치 교체"]
  CLASS["새 SSD/HDD class"]
  PLAN["health·backup·장치 identity·CRUSH 영향 plan"]
  ONE["한 번에 OSD 하나 또는 검토된 failure domain"]
  RECOVER["recovery/backfill 완료"]
  VERIFY["pool rule·Cinder I/O·HEALTH_OK"]

  NEED --> CAP
  NEED --> FAIL
  NEED --> CLASS
  CAP --> PLAN
  FAIL --> PLAN
  CLASS --> PLAN
  PLAN --> ONE --> RECOVER --> VERIFY
```

- `HEALTH_OK`와 최근 검증된 외부 backup 없이 변경하지 않는다.
- `/dev/sdX` 대신 topology와 실제 label이 일치하는 `/dev/disk/by-id`와 serial을 사용한다.
- 서로 다른 `hdd`, `ssd`, `nvme` class를 하나의 CRUSH rule에 우연히 섞지 않는다.
- 한 OSD 작업이 recovery를 끝내기 전에 다음 OSD를 변경하지 않는다.
- pool `size=3/min_size=2`와 host failure domain을 유지한다.
- Ceph replication을 backup으로 간주하지 않는다.

## 변경 전 기록

```bash
export CEPH_CHANGE_ID="$(date -u +%Y%m%dT%H%M%SZ)-osd-change"
mkdir -m 0700 -p ".cache/ceph/changes/$CEPH_CHANGE_ID"
sudo cephadm shell -- ceph -s >".cache/ceph/changes/$CEPH_CHANGE_ID/ceph-s.txt"
sudo cephadm shell -- ceph health detail >".cache/ceph/changes/$CEPH_CHANGE_ID/health.txt"
sudo cephadm shell -- ceph osd tree >".cache/ceph/changes/$CEPH_CHANGE_ID/osd-tree.txt"
sudo cephadm shell -- ceph osd df tree >".cache/ceph/changes/$CEPH_CHANGE_ID/osd-df.txt"
sudo cephadm shell -- ceph osd pool ls detail --format json \
  >".cache/ceph/changes/$CEPH_CHANGE_ID/pools.json"
sudo cephadm shell -- ceph osd crush rule dump \
  >".cache/ceph/changes/$CEPH_CHANGE_ID/crush-rules.txt"
```

`.cache` 기록은 Git에 넣지 않는다. 작업 전후 비교용이며 최종 결과는 암호화된 운영 기록으로
옮긴다.

대상 host에서 다음을 확인한다.

```bash
ls -l /dev/disk/by-id/
lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,ROTA,TRAN,FSTYPE,MOUNTPOINTS
sudo wipefs --no-act /dev/disk/by-id/<검토한-장치>
sudo smartctl -x /dev/disk/by-id/<검토한-장치>
```

`wipefs --no-act` 결과, holder, mount, LVM PV, mdraid 또는 기존 Ceph signature가 있으면 추가 OSD
후보로 승인하지 않는다. 기존 데이터를 지우는 명령은 이 문서에서 자동 실행하지 않는다.

## 용량 증설 설계

### 기존 class 확장

현재 OpenStack pool이 `nvme`라면 추가 NVMe를 어느 host에 둘지 결정한다. 한 host에만 OSD를 많이
추가하면 host 장애 시 손실되는 raw 비율과 recovery 부하가 커진다. 세 failure domain에 같은
class와 비슷한 용량을 균형 있게 추가하는 것을 기본으로 한다.

| 확인 | 판단 기준 |
| --- | --- |
| 현재 사용률 | 70%에서 구매·작업 계획, 75% 전에 여유 확보 |
| host별 raw | 한 host 장애 후 `min_size=2` I/O를 유지할 수 있는지 |
| recovery 여유 | 새 OSD 추가 중 VM latency를 감당할 수 있는 시간대인지 |
| network | 10Gbps error/drop과 switch 여유가 정상인지 |
| memory | 추가 OSD의 memory target을 converged host가 감당하는지 |

### 새 class 추가

SATA SSD는 `ssd`, HDD는 `hdd` class로 세 host 이상에 준비한다. 새 class에는 다음을 각각 만든다.

1. class와 host failure domain을 선택하는 별도 CRUSH rule
2. 목적별 pool과 `size=3/min_size=2`
3. 필요하면 Cinder backend/volume type과 명확한 이름
4. 해당 type으로 volume 생성, attach, write/read, detach 시험
5. 용량과 latency를 구분한 모니터링

HDD pool을 VM root와 latency-sensitive database의 기본 type으로 만들지 않는다. archive나 backup
목적을 명시한다.

## OSD 추가 변경 계획

실제 적용 전 다음 내용이 채워진 변경 기록을 만든다.

```text
change ID:
Ceph FSID:
대상 host:
정확한 by-id:
serial / model / size / class:
예상 OSD 수와 host별 raw 변화:
사용할 CRUSH rule과 영향 pool:
최근 backup ID와 restore 검증일:
관찰할 VM/Cinder 시험 workload:
중단 기준:
원복 또는 장치 격리 방법:
```

cephadm의 실제 OSD 추가 명령과 service spec 형식은 pin된 Ceph 버전에 맞춰 검토하고 dry-run
출력을 변경 기록에 첨부한다. 현재 repository wrapper에는 운영 OSD 추가 승인값, dry-run digest와
사후 topology reconciliation이 없으므로 직접 적용을 정식 자동화 완료로 간주하지 않는다.

## 장애 OSD 교체

OSD `down`만으로 즉시 디스크 고장이라고 판단하지 않는다. daemon, host 전원, NIC, SMART와 kernel
log를 함께 확인한다.

```bash
sudo cephadm shell -- ceph health detail
sudo cephadm shell -- ceph orch ps --daemon-type osd
sudo cephadm shell -- ceph osd tree
ssh <host> 'sudo journalctl -k --since "-2 hours"'
ssh <host> 'sudo smartctl -x /dev/disk/by-id/<대상-장치>'
```

교체 전 반드시 OSD ID와 실제 by-id/serial의 연결을 확인한다. Ceph가 해당 OSD를 안전하게 제거할
수 있다고 판정하기 전에는 purge, zap 또는 물리 제거를 실행하지 않는다. 정확히 세 host와 세
OSD뿐인 초기 구성에서는 OSD 하나를 제거한 동안 세 번째 복제본을 다른 host에 재생성할 수 없다.
따라서 교체 시간 전체가 degraded 상태이며 두 번째 장애를 허용하지 않는다.

대상 OSD ID를 실제 관찰 결과로 정한 뒤 다음 읽기 전용 조회와 안전 판정을 기록한다.

```bash
sudo cephadm shell -- ceph osd find <확인한-osd-id>
sudo cephadm shell -- ceph osd metadata <확인한-osd-id>
sudo cephadm shell -- ceph device ls-by-daemon osd.<확인한-osd-id>
sudo cephadm shell -- ceph osd safe-to-destroy <확인한-osd-id>
```

`safe-to-destroy`가 실패하면 제거 작업을 진행하지 않는다. 성공하더라도 ID와 serial 대응, 두 번째
장애 유무와 backup을 다시 확인해야 하며, 이 판정 자체가 purge 승인은 아니다.

교체 순서는 다음 상태 전이로 관리한다.

1. 원인 확인과 대상 identity 고정
2. backup/복원 검증과 유지보수 시간 확보
3. Ceph safe-to-destroy 판정 및 제거 plan 검토
4. OSD daemon/CRUSH/auth 제거를 pin된 Ceph 절차로 실행
5. host에서 정확한 serial의 장치만 물리 교체
6. 새 by-id/serial/class를 local topology에 반영
7. 새 OSD 적용, `up/in`, recovery/backfill 완료 대기
8. pool rule, 사용률, Cinder I/O와 `HEALTH_OK` 검증

## 변경 중 관찰과 중단

```bash
watch -n 10 'sudo cephadm shell -- ceph -s'
sudo cephadm shell -- ceph progress
sudo cephadm shell -- ceph osd df tree
```

다음이면 새 OSD 작업을 추가하지 않는다.

- inactive/undersized PG가 예상 범위를 벗어나 증가
- 두 번째 OSD 또는 host 이상
- client I/O timeout이나 Cinder volume 오류
- Ceph network error/drop 또는 host memory pressure
- recovery 완료 예상이 유지보수 시간을 초과

## 완료 기준

- 모든 의도한 OSD가 `up/in`이며 class와 host 위치가 계획과 같다.
- `images`, `volumes`, `vms`와 새 pool이 의도한 CRUSH rule, size, min_size를 사용한다.
- recovery/backfill이 끝나고 `HEALTH_OK`다.
- 시험 Cinder volume의 생성·attach·write/read·detach·delete가 성공한다.
- topology의 by-id/serial과 실제 장치가 일치한다.
- host별 raw와 사용률 불균형을 기록했다.
- 변경 후 새 backup과 [장애 훈련](failure-drills.md) 범위를 갱신했다.

운영 OSD 변경을 반복할 계획이라면 수동 명령을 계속 복사하지 말고, 최초 배포 guard와 분리된
`day2 osd plan/apply/status` 자동화를 먼저 구현한다.

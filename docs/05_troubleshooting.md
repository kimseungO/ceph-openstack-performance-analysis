# Troubleshooting 기록

구축 및 실험 과정에서 발생한 장애와 해결 과정을 기록합니다.  
단순 해결책 나열이 아닌, **원인 분석 → 판단 근거 → 해결** 흐름으로 작성했습니다.

---

## 목차

1. [oslo.config 파싱 에러로 인한 배포 중단](#1-osloconfig-파싱-에러로-인한-배포-중단)
2. [cinder-backup Keyring 누락으로 배포 실패](#2-cinder-backup-keyring-누락으로-배포-실패)
3. [Floating IP 할당 후 통신 불가](#3-floating-ip-할당-후-통신-불가)
4. [벤치마크 대조군 설계 오류](#4-벤치마크-대조군-설계-오류)
5. [Block Size 차이로 인한 rados bench 지연 폭증](#5-block-size-차이로-인한-rados-bench-지연-폭증)

---

## 1. oslo.config 파싱 에러로 인한 배포 중단

### 증상

`kolla-ansible reconfigure` 실행 중 아래 에러와 함께 배포 중단.

```
oslo_config.iniparser.ParseError: Unexpected continuation line
```

### 원인 분석

에러 메시지의 `Unexpected continuation line`을 추적하여 문제 파일을 특정했습니다.

Cephadm이 자동 생성한 `ceph.conf`를 Kolla 커스텀 디렉토리(`/etc/kolla/config/ceph/`)에 복사했는데, 이 파일 내부에 들여쓰기로 **탭(Tab, `\t`) 문자**가 사용되어 있었습니다.

OpenStack의 설정 파서인 `oslo.config`는 INI 파일 형식을 기반으로 동작하며, **탭 문자를 설정값의 연속(continuation)으로 오인**해 구문 분석 오류를 발생시킵니다.

```
# 문제가 된 ceph.conf 형태 (탭 문자 포함)
[global]
	fsid = 26705e26-...     ← 탭 문자로 시작
	mon_host = [v2:...]
```

### 해결

`sed` 명령으로 해당 파일 내 탭 문자를 스페이스로 일괄 치환 후 재배포.

```bash
sed -i 's/\t/    /g' /etc/kolla/config/ceph/ceph.conf
kolla-ansible reconfigure -i multinode
```

### 교훈

자동 생성된 설정 파일을 타 시스템에 그대로 복사할 때는, 대상 시스템의 파서 규격을 먼저 확인해야 합니다. 동일한 내용이라도 **공백 문자 하나의 차이가 배포 전체를 중단**시킬 수 있습니다.

---

## 2. cinder-backup Keyring 누락으로 배포 실패

### 증상

`kolla-ansible deploy` 중 cinder-backup 컨테이너 기동 실패.

```
FAILED: cinder-backup container failed to start
ceph.client.cinder-backup.keyring: No such file or directory
```

### 원인 분석

`globals.yml`에 `cinder_backend_ceph: "yes"`를 선언하면, Kolla-Ansible은 Cinder 백업 백엔드도 자동으로 Ceph로 지정합니다. 이때 `ceph.client.cinder-backup.keyring` 파일을 필수로 요구합니다.

단일 물리 디스크 환경에서 백업 풀을 만드는 것은 의미가 없습니다. 원본과 백업이 동일한 디스크에 저장되면 디스크 장애 시 둘 다 소실되므로 DR(재해 복구) 목적을 달성하지 못합니다. 따라서 백업 풀과 키링을 생성하지 않았으나, 자동화 엔진이 이를 강제 요구한 것입니다.

### 해결

`globals.yml`에 백업 데몬 비활성화 파라미터를 명시적으로 추가.

```yaml
# /etc/kolla/globals.yml
enable_cinder_backup: "no"
```

### 교훈

자동화 배포 도구는 **묵시적 의존성(Implicit Dependency)**을 가지는 경우가 많습니다. 옵션 하나를 활성화하면 연관 컴포넌트들이 연쇄적으로 활성화될 수 있으므로, 불필요한 컴포넌트는 명시적으로 비활성화하는 것이 안전합니다.

---

## 3. Floating IP 할당 후 통신 불가

### 증상

OpenStack에서 VM에 Floating IP를 할당했으나 호스트 OS에서 `ping`이 응답하지 않음.

```bash
ping 192.168.0.242
# Request timeout
```

### 원인 분석

네트워크 장애를 계층별로 추적했습니다.

**L3 확인:** `ip route`, `iptables -L` → 라우팅 테이블과 NAT 규칙 정상.

**L2 확인:** 브리지에 바인딩된 물리 인터페이스 상태 점검.

```bash
ip link show enp7s0
# state DOWN  ← 물리 포트가 Down 상태
```

Provider 네트워크용으로 설정한 물리 NIC(`enp7s0`, `enp8s0`)의 Link State가 Down이었습니다. 브리지가 구성되어 있어도 **물리 포트가 Down이면 L2 프레임 자체가 전달되지 않습니다.**

### 해결

```bash
sudo ip link set enp7s0 up
sudo ip link set enp8s0 up
```

이후 즉시 ping 응답 확인.

### 교훈

네트워크 장애는 **상위 레이어(L3, 방화벽)부터 먼저 의심하기 쉽지만**, 이 케이스처럼 L2 물리 링크가 원인인 경우도 많습니다. `ip link show`로 물리 인터페이스 상태를 먼저 확인하는 습관이 중요합니다.

---

## 4. 벤치마크 대조군 설계 오류

### 증상

Scenario 1(qcow2 오버헤드 측정) 진행 중, 대조군을 Ceph RBD 볼륨으로 설정했더니 IOPS가 95% 하락. 이를 qcow2 오버헤드로 해석할 뻔함.

### 원인 분석

실험 설계의 **변인 통제 실패**였습니다.

| 비교군 | I/O 경로 | 변인 |
|--------|----------|------|
| qcow2 | VM → qcow2 파일 → NVMe | 가상화 파일시스템 오버헤드 |
| Ceph RBD (잘못된 대조군) | VM → Ceph 네트워크 → OSD × 3 → NVMe | 가상화 + 분산 네트워크 + 3중 복제 |

qcow2 파일시스템 오버헤드와 Ceph 분산 네트워크 페널티가 동시에 섞여있어, 95% 하락의 원인이 무엇인지 분리할 수 없는 데이터가 나왔습니다.

### 해결

`virsh attach-disk`로 호스트의 물리 파티션을 VM에 직접 Raw Mapping하여 **순수한 로컬 I/O 환경**을 대조군으로 재설계.

```bash
# 호스트에서 임시 Raw 블록 디바이스를 VM에 직접 연결
virsh attach-disk ubuntu01 /dev/nvme1n1p6 vdc --driver qemu --subdriver raw
```

이로써 두 비교군의 유일한 차이가 **qcow2 파일시스템 레이어 유무**로 통제됨.

### 교훈

벤치마크에서 **변인 통제는 결과 해석의 전제 조건**입니다. 비교 대상 간의 차이가 측정하려는 변인 하나뿐이어야 의미 있는 수치가 나옵니다. 초기 설계 오류를 발견하고 스스로 재설계한 과정 자체가 실험 방법론 이해도를 보여줍니다.

---

## 5. Block Size 차이로 인한 rados bench 지연 폭증

### 증상

Scenario 3 초기 실험에서 측정 도구별 지연 시간이 1,000배 이상 차이남.

| 측정 도구 | 설정 | 관측 지연 |
|-----------|------|-----------|
| fio | 4KB, Rate Limited | ~0.1ms |
| rados bench | 4MB, 무제한 | **~119ms** |

### 원인 분석

두 도구의 **워크로드 조건이 완전히 달랐습니다.**

rados bench의 4MB 블록 × 무제한 전송 → 초당 약 536MB/s 생성. Replica 3 복제를 거치며 단일 NVMe에 약 1.3GB/s가 집중. NVMe 컨트롤러(PCIe 대역폭) 처리 한계 초과 → `w_await` 2.06ms로 급등 → Ceph 전체 지연 119ms로 전파.

이는 네트워크나 Ceph 소프트웨어가 아닌, **물리 하드웨어 대역폭 포화(Hardware Saturation)**가 원인이었습니다.

그러나 더 근본적인 문제는 **비교 불가능한 조건으로 측정한 것** 자체였습니다. 조건이 다른 두 도구의 결과를 같은 표에 올려 비교한 것은 방법론적 오류였습니다.

### 해결

Scenario 3를 완전히 재설계했습니다.

- **조건 통일:** fio(4KB randwrite)를 단일 워크로드로 고정
- **동시 관측:** fio 실행 중 `ceph osd perf`, `iostat -x`를 동시에 수집
- **libaio 전환:** psync 대신 libaio 엔진 사용으로 실제 iodepth 활용

재설계 결과, 극한 부하에서도 NVMe %util이 20%를 넘지 않았고 병목이 **Ceph OSD 소프트웨어 처리 큐**임을 정확히 분리해 낼 수 있었습니다.

→ 재설계된 실험 결과: [docs/04_scenario3.md](04_scenario3.md)

### 교훈

측정 도구마다 기본 워크로드가 다릅니다. 계층별 비교 실험을 설계할 때는 **모든 도구에서 워크로드 조건을 통일**하는 것이 전제입니다. 잘못된 설계를 스스로 발견하고 재실험한 이 과정이 최종 결과물의 신뢰성을 높였습니다.

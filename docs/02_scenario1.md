# Scenario 1: 가상화 I/O 오버헤드 — qcow2 vs Raw Mapping

## 목적

KVM 하이퍼바이저에서 OSD 데이터 디스크를 구성하는 두 방식,  
**qcow2(동적 가상 디스크)** 와 **Raw Mapping(물리 파티션 직접 패스스루)** 간의  
I/O 성능 차이를 정량적으로 측정하고, 차이의 원인을 구조적으로 분석한다.

---

## 배경: 왜 이 비교가 필요한가

Ceph OSD는 데이터를 물리 디스크에 직접 기록합니다.  
그런데 KVM 가상화 환경에서는 VM이 인식하는 디스크가 실제 물리 디스크가 아닐 수 있습니다.

| 방식          | 가상 머신(VM) 가시성 | 실제 데이터 입출력 경로                           |
|---------------|----------------------|---------------------------------------------------|
| qcow2         | 가상 블록 디바이스   | VM → qcow2 파일(호스트 파일시스템) → NVMe         |
| Raw Mapping   | 가상 블록 디바이스   | VM → 물리 파티션 → NVMe                           |

qcow2는 **동적 할당(Dynamic Provisioning)** 포맷입니다.  
파일이 커질 때마다 L2 테이블이라는 메타데이터를 갱신하는 구조로,  
이 갱신 작업이 I/O 경로에 추가 오버헤드를 만듭니다.

Raw Mapping은 이 레이어 없이 물리 파티션에 직접 접근합니다.

---

## 실험 설계

### 비교 구성

| 항목          |    qcow2 (대조군)    |      Raw Mapping (실험군)      |
|---------------|:--------------------:|:------------------------------:|
| 디스크 구성   | 호스트 FS 위 이미지  | 호스트 NVMe 파티션 직접 패스스루 |
| KVM 설정      | `--subdriver qcow2`  |       `--subdriver raw`        |
| 대상 파티션   |          -           |         nvme1n1p3~p5           |

> **변인 통제:**  
> 두 비교군의 유일한 차이는 KVM 디스크 레이어 방식입니다.  
> CPU, RAM, NVMe 하드웨어, fio 워크로드 조건은 완전히 동일합니다.  
> (초기 실험에서 Ceph RBD를 대조군으로 사용해 변인이 섞인 오류를 수정한 설계입니다.
> → [Troubleshooting #4](05_troubleshooting.md) 참고)

### fio 측정 조건

```bash
fio \
  --filename=/dev/vdb \
  --direct=1 \          # OS 페이지 캐시 우회, 디스크 직접 타격
  --rw=randwrite \      # 4KB 랜덤 쓰기 (Ceph OSD 실제 워크로드와 유사)
  --bs=4k \
  --iodepth=32 \
  --numjobs=4 \
  --runtime=120 \
  --time_based \
  --group_reporting
```

---

## 실험 결과

| 항목               |     qcow2     |     Raw Mapping      |      변화      |
|--------------------|:-------------:|:--------------------:|:--------------:|
| **IOPS**           |    238,000    |     **269,000**      |   **+13.0%**   |
| **Bandwidth**      |   932 MiB/s   |   **1,050 MiB/s**    |   **+12.6%**   |
| **평균 Latency**   |   133.94 µs   |     **118.77 µs**    |   **-11.3%**   |
| **p99 Latency**    |       -       |           -          |        -       |
| **p99.99 Latency** |    1,385 µs   |       **685 µs**     |   **-50.5%**   |

---

## 분석

### IOPS / Bandwidth: 13% 향상

Raw Mapping 전환으로 초당 처리량이 약 13% 증가했습니다.  
qcow2의 L2 테이블 갱신 연산이 제거되어 I/O 경로가 짧아진 결과입니다.

### Tail Latency: 50% 감소 — 더 중요한 수확

IOPS 13% 향상보다 **p99.99 Latency가 1,385µs → 685µs로 절반 이하**로 줄어든 것이 핵심입니다.

이유는 qcow2의 쓰기 동작 구조에 있습니다.

```
qcow2 쓰기 동작:

1. 데이터 블록 쓰기
2. L2 테이블(메타데이터) 갱신  ← 이 단계가 불규칙하게 발생
3. 완료
```

L2 테이블 갱신은 **모든 쓰기마다 발생하지 않습니다.**  
새로운 클러스터가 할당될 때만 발생하며, 이 순간 특정 요청만 갑자기 오래 걸립니다.  
대부분의 요청은 빠른데 일부 요청이 예측 불가능하게 지연되는 것,  
이게 **Tail Latency(꼬리 지연)**의 정체입니다.

```
qcow2 Latency 분포:
대부분의 요청 ──────────────────────────── 빠름
가끔 요청     ───────────────────────────────────────── 느림 (L2 갱신 시점)
                                                        ↑ p99.99 = 1,385µs

Raw Mapping Latency 분포:
모든 요청     ──────────────────────── 균일하게 빠름
                                       ↑ p99.99 = 685µs
```

Raw Mapping은 이 메타데이터 갱신 단계 자체가 없으므로  
I/O 지연이 균일해지고 Tail Latency가 절반 이하로 떨어집니다.

### 실제 운영 관점에서의 의미

클라우드 스토리지 서비스에서 Tail Latency는 중요한 지표입니다.  
p99.99는 "10,000번 요청 중 가장 느린 1번"입니다.

초당 10,000 IOPS 환경에서 p99.99가 1,385µs라면,  
매 초마다 1개의 요청이 1.4ms 지연됩니다.

Ceph OSD처럼 대량의 I/O를 처리하는 서비스에서 이런 스파이크가 쌓이면  
상위 레이어(클라이언트)의 Latency 분포를 흔들 수 있습니다.  
OSD 디스크를 Raw Mapping으로 구성하는 것은 이 스파이크를 제거하는 선택입니다.

---

## 결론

| 항목              | 내용                                                          |
|-------------------|---------------------------------------------------------------|
| IOPS 향상         | +13%                                                          |
| Tail Latency 개선 | **-50.5%** (시스템 안정성 측면에서 가장 유의미한 지표)        |
| 원인 분석         | qcow2 L2 테이블 메타데이터 갱신에 따른 I/O 스파이크 제거      |
| 향후 적용         | Ceph OSD 데이터 디스크 전체에 Raw Mapping 아키텍처 도입       |

> **qcow2 대비 Raw Mapping의 핵심 이점은 평균 성능 향상(13%)이 아니라  
> Tail Latency 안정화(50% 감소)에 있다.  
> I/O 스파이크의 원인인 qcow2 L2 테이블 갱신 레이어를 제거함으로써  
> OSD의 쓰기 지연 분포가 균일해진다.**

---

## 측정 스크립트

```bash
# scripts/bench_scenario1.sh 참고

# qcow2 방식 (기본 VM 디스크)
sudo fio --filename=/dev/vdb --direct=1 \
    --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 \
    --runtime=120 --time_based --group_reporting \
    --name=qcow2-test --output=result_qcow2.txt

# Raw Mapping 방식 (물리 파티션 직접 연결)
# virsh attach-disk로 Raw 블록 디바이스를 VM에 연결한 후
sudo fio --filename=/dev/vdc --direct=1 \
    --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 \
    --runtime=120 --time_based --group_reporting \
    --name=raw-test --output=result_raw.txt
```

← [README로 돌아가기](../README.md)

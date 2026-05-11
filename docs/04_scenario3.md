# Scenario 3: I/O 파이프라인 병목 계층 분리 분석

## 목적

동일한 워크로드 하에서 I/O 지연(Latency)의 원인이  
**Application → Ceph OSD → 물리 NVMe** 중 어느 레이어에서 발생하는지  
세 도구를 동시에 관측하여 계층별로 분리 진단한다.

---

## 실험 설계

### 측정 레이어 구조

```
┌─────────────────────────────────────┐
│  bench-vm (OpenStack Instance)      │
│  fio → /dev/vdb (Ceph RBD Volume)   │  ← Application 레이어
└──────────────┬──────────────────────┘
               │ Ceph 내부 네트워크
┌──────────────▼──────────────────────┐
│  Ceph OSD × 3 (BlueStore Engine)    │  ← Storage Software 레이어
│  ceph osd perf → apply_lat 관측     │
└──────────────┬──────────────────────┘
               │ Raw Device Mapping
┌──────────────▼──────────────────────┐
│  NVMe SSD (nvme1n1p3~p5)            │  ← Physical Hardware 레이어
│  iostat -x → w_await / %util 관측   │
└─────────────────────────────────────┘
```

### 동시 관측 설계

모든 지표를 **같은 시간축**에서 수집하는 것이 핵심입니다.  
fio 단일 워크로드를 기준으로 나머지 도구는 동시 관측만 수행합니다.

```bash
# 터미널 1: 워크로드 발생 (bench-vm)
fio --filename=/dev/vdb --ioengine=libaio ...

# 터미널 2: Storage Software 레이어 (controller)
watch -n 1 'ceph osd perf'

# 터미널 3: Cluster 상태 (controller)
watch -n 1 'ceph -s'

# 터미널 4: Physical Hardware 레이어 (호스트)
iostat -x 1 nvme1n1p3 nvme1n1p4 nvme1n1p5
```

### 실험 조건

|    항목   |              공통 조건               |
|-----------|--------------------------------------|
| 대상      | /dev/vdb (Cinder RBD 볼륨, Replica 3) |
| I/O 패턴  | 4K randwrite, direct=1               |
| I/O 엔진  | libaio (비동기)                       |
| 실행 시간 | 120초                                 |

| 구분     | iodepth | numjobs | 총 Queue Depth |
|----------|---------|---------|----------------|
| Baseline | 32      | 4       | **128**        |
| Stress   | 128     | 8       | **1,024**      |

> **psync → libaio 전환 이유:**  
> psync(동기 엔진)는 iodepth 설정을 무시하고 항상 depth=1로 동작합니다.  
> I/O를 하나 보내고 완료될 때까지 기다린 후 다음을 전송하기 때문입니다.  
> NVMe의 다중 큐(Multi-Queue) 특성을 활용하려면 libaio(비동기 엔진)가 필수입니다.

---

## 실험 결과

### 전체 수치 비교

| 항목                  |     psync      | libaio Baseline  |   libaio Stress   |
|-----------------------|:--------------:|:----------------:|:-----------------:|
| **ioengine**          |     psync      |      libaio      |       libaio      |
| **iodepth × numjobs** |     32 × 4     |      32 × 4      |      128 × 8      |
| **총 Queue Depth**    |  128 (실효 4)  |     **128**      |     **1,024**     |
|                       |                |                  |                   |
| **IOPS**              |     1,591      |      8,709       |       9,811       |
| **Bandwidth**         |   6.2 MiB/s    |    34.0 MiB/s    |     38.3 MiB/s    |
|                       |                |                  |                   |
| **평균 Latency**      |     2.5ms      |     14.68ms      |    **104.29ms**   |
| **p50 Latency**       |       -        |       14ms       |        85ms       |
| **p99 Latency**       |     5.0ms      |       32ms       |      **393ms**    |
| **p99.99 Latency**    |     16.9ms     |      171ms       |      **634ms**    |
|                       |                |                  |                   |
| **slat (제출 지연)**  |       -        |      11.4µs      |      **801µs**    |
| **iostat w_await**    |     0.10ms     |      0.07ms      |     **0.06ms**    |
| **NVMe %util**        |       -        |     12~22%       |     **10~20%**    |
| **ceph apply_lat**    |     0~1ms      |      4~7ms       |     **5~11ms**    |

### fio 원본 출력 요약

**libaio Baseline**
```
write: IOPS=8709, BW=34.0MiB/s
  clat (msec): avg=14.68, stdev=5.72
    p99=32ms / p99.99=171ms
  IO depths: 32=100.0%    ← iodepth 정상 동작 확인
  slat (nsec): avg=11,425
```

**libaio Stress**
```
write: IOPS=9811, BW=38.3MiB/s
  clat (msec): avg=104.29, stdev=70.68
    p99=393ms / p99.99=634ms
  IO depths: >=64=100.0%  ← iodepth=128 정상 동작 확인
  slat (nsec): avg=801,527
```

---

## 분석

### 발견 1: ioengine이 IOPS를 5.5배 결정한다

psync와 libaio의 유일한 차이는 I/O 엔진입니다.  
하드웨어, 워크로드, Queue Depth 설정은 모두 동일합니다.

```
psync  → IOPS 1,591  (iodepth 설정 무시, 실효 depth=1)
libaio → IOPS 8,709  (iodepth=32 정상 활용)

차이: 5.47배
```

클라우드 스토리지 클라이언트 설정에서  
**I/O 엔진 선택이 하드웨어 교체보다 더 큰 성능 차이**를 만들 수 있음을 의미합니다.

### 발견 2: 극한 부하에서 NVMe는 포화되지 않았다

Queue Depth를 128 → 1,024(8배)로 늘렸을 때 물리 디스크 지표는 오히려 안정적이었습니다.

```
w_await: 0.07ms → 0.06ms  (감소)
%util:   12~22% → 10~20%  (감소)
```

NVMe SSD는 극한 부하에서도 처리 여력이 남아 있었습니다.  
반면 IOPS는 8,709 → 9,811로 **12.6% 증가에 그쳤고**,  
평균 Latency는 14.68ms → 104.29ms로 **610% 폭증**했습니다.

### 발견 3: 병목은 Ceph OSD 소프트웨어 큐였다

slat(Submission Latency)는 fio가 I/O 요청을 커널에 제출하는 데 걸린 시간입니다.

```
Baseline slat: 11.4µs
Stress   slat: 801µs   → 70배 증가
```

Ceph 내부 큐가 포화되어 **요청 접수 자체**가 지연된 것입니다.  
물리 디스크가 아니라 **BlueStore 처리 파이프라인이 먼저 한계**에 도달했습니다.

```
병목 위치:

[bench-vm] → [Ceph OSD 큐 ← 여기서 막힘] → [NVMe ← 여유 있음]
```

### 발견 4: Little's Law로 측정 신뢰성 검증

`Latency = Queue Depth / Throughput`

이 공식으로 실측값을 역산하여 실험의 신뢰성을 수학적으로 검증합니다.

```
Baseline:  128  ÷ 8,709  = 14.70ms   (실측 14.68ms ✓)
Stress:   1,024 ÷ 9,811  = 104.37ms  (실측 104.29ms ✓)
```

**수식과 실측값이 0.1% 오차 이내로 일치합니다.**  
실험 중 외부 노이즈가 거의 없었으며, Ceph의 I/O 큐 동작이 이론대로 동작함을 증명합니다.

---

## 결론

| 질문 : 답 |
|------:-----|
| 병목은 어디인가? : Ceph OSD 소프트웨어 처리 큐 |
| NVMe는 포화됐는가? : 아니오 — %util 최대 22%, w_await 0.06ms |
| IOPS는 왜 12%밖에 안 늘었는가? : OSD 큐가 먼저 포화되어 처리량 증가가 제한됨 |
| Latency는 왜 610% 폭증했는가? : 큐 깊이 8배 ÷ 처리량 1.13배 → Little's Law에 의해 7배 증가 |

> **단일 스핀들 HCI 환경에서 I/O 부하를 극단적으로 증가시켰을 때,  
> 병목은 물리 NVMe가 아니라 Ceph BlueStore OSD 소프트웨어 처리 레이어였다.  
> 이를 Application / Storage Software / Physical Hardware 세 계층의 동시 관측으로 분리 진단했다.**

---

## 측정 스크립트

```bash
# scripts/bench_scenario3.sh 참고

# [터미널 3] controller
watch -n 1 'ceph osd perf'

# [터미널 4] 호스트
iostat -x 1 nvme1n1p3 nvme1n1p4 nvme1n1p5 | tee iostat_s3.log

# [터미널 2] controller
watch -n 1 'ceph -s'

# [터미널 1] bench-vm - Baseline
sudo fio --filename=/dev/vdb --direct=1 --ioengine=libaio \
    --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 \
    --runtime=120 --time_based --group_reporting \
    --name=baseline --output=result_baseline.txt

# [터미널 1] bench-vm - Stress
sudo fio --filename=/dev/vdb --direct=1 --ioengine=libaio \
    --rw=randwrite --bs=4k --iodepth=128 --numjobs=8 \
    --runtime=120 --time_based --group_reporting \
    --name=stress --output=result_stress.txt
```

← [README로 돌아가기](../README.md)

# Scenario 2: 쓰기 증폭(Write Amplification) — Replica 2 vs 3

## 목적

Ceph의 복제(Replica) 정책이 물리 디스크에 실제로 얼마나 많은 쓰기를 유발하는지,  
클라이언트 쓰기량(fio)과 물리 디스크 쓰기량(iostat)을 교차 측정하여  
**쓰기 증폭률(WAF, Write Amplification Factor)**을 정량적으로 측정하고  
이론값과 실측값의 차이 원인을 분석한다.

---

## 배경: Write Amplification이란

클라이언트가 1MB를 쓴다고 해서 물리 디스크에 1MB만 기록되지 않습니다.  
분산 스토리지에서는 여러 요인이 물리 쓰기를 증폭시킵니다.

```
클라이언트 → 1MB 쓰기 요청
                ↓
Ceph 내부 → 실제 물리 디스크에는 N×MB 기록
```

이 비율이 WAF입니다. `WAF = 물리 디스크 쓰기량 / 클라이언트 쓰기량`

### 이론값

| Replica 정책 | 이론 WAF | 이유 |
|:------------:|:--------:|------|
| Replica 2 | 2x | 동일 데이터를 OSD 2개에 복제 |
| Replica 3 | 3x | 동일 데이터를 OSD 3개에 복제 |

**그런데 실측값은 이론값보다 훨씬 높습니다.** 그 이유를 이 실험으로 규명합니다.

---

## 실험 설계

### 핵심 아이디어

클라이언트 쓰기 속도를 **고정(Rate Limit)**하면,  
물리 디스크가 실제로 얼마나 더 많이 쓰는지를 정확히 비교할 수 있습니다.

```
fio --rate=50m   → 클라이언트 쓰기 50 MiB/s 고정
iostat           → 물리 NVMe 실제 쓰기량 측정
WAF              = iostat 측정값 / 52.4 MB/s(클라이언트)
```

### 실험 조건

| 항목 | 조건 |
|------|------|
| 클라이언트 쓰기 속도 | 50 MiB/s 고정 (Rate Limited) |
| I/O 패턴 | 4K sequential write, direct=1 |
| I/O 엔진 | libaio, iodepth=32 |
| 실행 시간 | 60초 |
| 비교 대상 | Replica 3 Pool ↔ Replica 2 Pool 전환 |

```bash
# Replica 3 → Replica 2 전환
ceph osd pool set volumes size 2
ceph osd pool set vms size 2
```

---

## 실험 결과

### WAF 측정

| 항목 | Replica 3 | Replica 2 |
|------|:---------:|:---------:|
| **클라이언트 쓰기 (fio BW)** | 50.0 MiB/s (52.4 MB/s) | 50.0 MiB/s (52.4 MB/s) |
| **물리 NVMe 쓰기 (iostat 최대)** | **300.05 MB/s** | **205.63 MB/s** |
| **실측 WAF** | **약 5.7x** | **약 3.9x** |
| **이론 WAF** | 3x | 2x |
| **초과 배율** | +2.7x | +1.9x |

### 클라이언트 Latency 비교

두 실험 모두 Rate Limit으로 동일한 부하를 줬기 때문에  
IOPS/BW는 동일하고, Latency 분포만 다릅니다.

| 항목 | Replica 3 | Replica 2 | 변화 |
|------|:---------:|:---------:|:----:|
| **평균 Latency** | 90.13 µs | 81.04 µs | **-10.1%** |
| **p50 Latency** | 42.2 µs | 40.7 µs | -3.6% |
| **p99 Latency** | 544.8 µs | 415.7 µs | **-23.7%** |
| **p99.99 Latency** | 3,883 µs | 3,981 µs | +2.5% |

### fio 원본 출력 요약

**Replica 3**
```
write: IOPS=12.8k, BW=50.0MiB/s
  clat avg=75,508 ns (75.5 µs)
  lat  avg=90.13 µs
  p99=544,768 ns / p99.99=3,883,008 ns
```

**Replica 2**
```
write: IOPS=12.8k, BW=50.0MiB/s
  clat avg=66,384 ns (66.4 µs)
  lat  avg=81.04 µs
  p99=415,744 ns / p99.99=3,981,312 ns
```

### iostat 원본 (핵심 수치)

**Replica 3** — `wkB/s` 최대값
```
nvme0n1  w/s=10731.50  wkB/s=300.05  w_await=0.11ms
```

**Replica 2** — `wkB/s` 최대값
```
nvme0n1  w/s=9838.50   wkB/s=205.63  w_await=0.10ms
```

---

## 분석

### 왜 이론값(3x, 2x)보다 실측값(5.7x, 3.9x)이 높은가

Ceph는 **BlueStore** 스토리지 엔진을 사용합니다.  
BlueStore는 데이터를 OSD에 기록할 때 세 단계를 거칩니다.

```
단계 1: WAL(Write-Ahead Log)에 먼저 기록
         ↓
단계 2: RocksDB 메타데이터 갱신
         ↓
단계 3: 실제 데이터 블록 기록
```

이 구조는 데이터 안전성을 보장하지만,  
**OSD 하나당 하나의 쓰기 요청이 실제로는 2~3번의 물리 쓰기**를 유발합니다.

여기에 Replica가 곱해집니다.

```
Replica 3 WAF 계산:
복제 배수(3) × BlueStore 내부 쓰기 오버헤드(~2x)
= 이론 최대 6x

실측 5.7x → 이론 범위 내에서 정확히 설명됨
```

```
Replica 2 WAF 계산:
복제 배수(2) × BlueStore 내부 쓰기 오버헤드(~2x)
= 이론 최대 4x

실측 3.9x → 이론 범위 내에서 정확히 설명됨
```

### Latency: Replica 줄이면 빨라지는가

평균 Latency와 p99는 Replica 2가 더 낮습니다.  
Replica 3에서는 복제가 3개 OSD에서 완료되어야 응답하므로  
가장 느린 OSD의 응답을 기다리는 시간이 추가됩니다.

다만 p99.99는 Replica 2가 오히려 소폭 높습니다(3,981 vs 3,883 µs).  
Rate Limit 환경에서 극단적 지연은 개별 OSD의 일시적 상태에 더 크게 영향받기 때문입니다.  
이 오차는 측정 환경의 단일 스핀들 구성 특성상 의미 있는 차이로 보기 어렵습니다.

### 운영 관점: 무엇을 선택해야 하는가

| | Replica 3 | Replica 2 |
|--|:---------:|:---------:|
| 내구성 | OSD 2개 동시 장애까지 허용 | OSD 1개 장애까지 허용 |
| WAF | 5.7x (디스크 소모 빠름) | 3.9x |
| 평균 Latency | 높음 | 낮음 |
| 적합한 용도 | 프로덕션, 중요 데이터 | 개발/테스트, 일시 데이터 |

CSP에서 블록 스토리지 서비스를 설계할 때,  
**Replica 정책은 가용성과 디스크 수명/비용 간의 트레이드오프**입니다.  
이 실험은 그 트레이드오프를 WAF 수치로 정량화합니다.

---

## 결론

| 항목 | 내용 |
|------|------|
| Replica 3 실측 WAF | **5.7x** (이론 3x 대비 약 2배) |
| Replica 2 실측 WAF | **3.9x** (이론 2x 대비 약 2배) |
| 이론값 초과 원인 | BlueStore WAL + RocksDB 이중 쓰기 구조 |
| Latency 차이 | Replica 3이 평균 10%, p99 기준 24% 높음 |

> **Ceph Replica 정책의 실제 WAF는 이론 복제 배수의 약 2배에 달한다.  
> 이는 BlueStore의 WAL 선기록 + RocksDB 메타데이터 갱신이 OSD마다 추가 쓰기를 유발하기 때문이다.  
> 클라이언트가 50 MiB/s를 쓸 때 Replica 3 환경에서는 물리 디스크에 최대 300 MB/s가 기록된다.**

---

## 측정 스크립트

```bash
# scripts/bench_scenario2.sh 참고

# Replica 3 측정
fio --name=write_amp_r3 --ioengine=libaio --iodepth=32 \
    --rw=write --bs=4k --direct=1 --size=1G --numjobs=1 \
    --runtime=60 --time_based --rate=50m --group_reporting \
    --output=result_replica3.txt

# 물리 디스크 동시 관측 (별도 터미널)
iostat -x 1 nvme1n1p3 nvme1n1p4 nvme1n1p5 | tee iostat_replica3.log

# Replica 2로 전환
ceph osd pool set volumes size 2

# Replica 2 측정 (동일 조건)
fio --name=write_amp_r2 --ioengine=libaio --iodepth=32 \
    --rw=write --bs=4k --direct=1 --size=1G --numjobs=1 \
    --runtime=60 --time_based --rate=50m --group_reporting \
    --output=result_replica2.txt

iostat -x 1 nvme1n1p3 nvme1n1p4 nvme1n1p5 | tee iostat_replica2.log
```

← [README로 돌아가기](../README.md)

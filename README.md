# 단일 HCI 환경에서 OpenStack + Ceph 분산 스토리지 I/O 성능 정량 분석

> **Quantitative I/O Performance Analysis of Ceph RBD on a Single-Node HCI Stack**

단일 물리 서버 위에 KVM + OpenStack + Ceph를 직접 구축하고,  
스토리지 파라미터와 I/O 패턴이 성능에 미치는 영향을 **계층별로 정량 측정**한 프로젝트입니다.

---

## 목차

1. [프로젝트 개요](#1-프로젝트-개요)
2. [환경 명세](#2-환경-명세)
3. [아키텍처](#3-아키텍처)
4. [실험 결과 요약](#4-실험-결과-요약)
   - [Scenario 1: 가상화 I/O 오버헤드 — qcow2 vs Raw Mapping](#scenario-1-가상화-io-오버헤드--qcow2-vs-raw-mapping)
   - [Scenario 2: 쓰기 증폭(WAF) — Replica 2 vs 3](#scenario-2-쓰기-증폭waf--replica-2-vs-3)
   - [Scenario 3: I/O 파이프라인 병목 계층 분리](#scenario-3-io-파이프라인-병목-계층-분리)
5. [핵심 발견](#5-핵심-발견)
6. [트러블슈팅](#6-트러블슈팅)
7. [실험 재현](#7-실험-재현)

---

## 1. 프로젝트 개요

### 배경

CSP(클라우드 서비스 제공사)가 운영하는 블록 스토리지 서비스는 대부분 Ceph RBD를 백엔드로 사용합니다.  
Ceph는 파라미터 설정(Replica 수, PG 수)과 I/O 엔진 선택에 따라 성능이 크게 달라지며,  
이 차이를 **레이어별로 분리해서 측정**하지 않으면 병목의 원인을 오판하기 쉽습니다.

### 목표

| 목표 | 내용 |
|------|------|
| 환경 구축 | 베어메탈 위에 KVM + OpenStack(Kolla-Ansible) + Ceph(cephadm) HCI 스택 직접 배포 |
| 측정 설계 | fio / ceph osd perf / iostat 동시 관측으로 계층별 병목 분리 |
| 정량 분석 | 파라미터 변화에 따른 IOPS, Latency(avg/p99/p99.99), WAF 수치 도출 |

### 측정 레이어 구조

```
[ fio ]            ← Application 레이어 (클라이언트 관점)
    ↓
[ ceph osd perf ]  ← Storage Software 레이어 (Ceph OSD 관점)
    ↓
[ iostat -x ]      ← Physical Hardware 레이어 (NVMe 디스크 관점)
```

---

## 2. 환경 명세

### 물리 호스트

| 항목 | 사양 |
|------|------|
| CPU | Intel Core i5-12400 (6C/12T) |
| Memory | 64GB DDR4 Dual Channel |
| Storage | 1TB NVMe SSD (단일 스핀들) |
| Host OS | Xubuntu 22.04 LTS (Bare-metal) |
| Hypervisor | KVM (Linux kernel 내장 Type-1 근접 구조) |

### VM 구성

| 노드 | 역할 | vCPU | RAM | OS 디스크 | 데이터 디스크 |
|------|------|------|-----|-----------|--------------|
| controller | OpenStack Controller / Ceph MON, MGR | 2 | 12GB | 100GB (qcow2) | - |
| ubuntu01 | Compute / Ceph OSD | 2 | 12GB | 50GB (qcow2) | 100GB (**Raw Mapping**) |
| ubuntu02 | Compute / Ceph OSD | 2 | 12GB | 50GB (qcow2) | 100GB (**Raw Mapping**) |
| ubuntu03 | Compute / Ceph OSD | 2 | 12GB | 50GB (qcow2) | 100GB (**Raw Mapping**) |

> **Raw Mapping 선택 이유:** OSD 데이터 디스크를 qcow2 가상 이미지 대신 호스트의 NVMe 물리 파티션(`nvme1n1p3~p5`)을 KVM에 직접 패스스루. Scenario 1에서 이 선택의 효과를 정량적으로 검증.

### 소프트웨어 스택

| 구성요소 | 버전 / 도구 |
|----------|------------|
| OpenStack | 2024.1 Caracal |
| 배포 엔진 | Kolla-Ansible (컨테이너 기반) |
| Ceph | Quincy 17.x |
| 배포 엔진 | cephadm (OpenStack과 라이프사이클 격리) |
| 스토리지 백엔드 | Ceph RBD (Cinder, Glance, Nova 통합) |

---

## 3. 아키텍처

```
┌─────────────────────────────────────────────────────┐
│                Xubuntu 22.04 (Bare-metal)            │
│                  Intel i5-12400 / 64GB               │
│                   1TB NVMe SSD                       │
│                                                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────┐ │
│  │controller│  │ ubuntu01 │  │ ubuntu02 │  │ubun..│ │
│  │          │  │          │  │          │  │  03  │ │
│  │OpenStack │  │ Compute  │  │ Compute  │  │Comp..│ │
│  │Controller│  │ Ceph OSD │  │ Ceph OSD │  │Ceph..│ │
│  │Ceph MON  │  │ /dev/vdb │  │ /dev/vdb │  │/dev..│ │
│  │  MGR     │  │(Raw Map) │  │(Raw Map) │  │(Raw) │ │
│  └──────────┘  └────┬─────┘  └────┬─────┘  └──┬───┘ │
│                     │             │            │     │
│              ┌──────▼─────────────▼────────────▼──┐  │
│              │  nvme1n1p3  nvme1n1p4  nvme1n1p5   │  │
│              │         1TB NVMe SSD               │  │
│              └───────────────────────────────────┘  │
│                                                      │
│  Network: Management(192.168.0.0/24) + Provider      │
└─────────────────────────────────────────────────────┘
```

**핵심 아키텍처 결정 사항** → [docs/01_architecture.md](docs/01_architecture.md) 참고

---

## 4. 실험 결과 요약

모든 실험은 bench-vm(OpenStack 인스턴스)에 Cinder RBD 볼륨을 연결한 상태에서 수행.  
측정 도구: `fio 3.28` / `ceph osd perf` / `iostat -x`

---

### Scenario 1: 가상화 I/O 오버헤드 — qcow2 vs Raw Mapping

> fio 조건: `4K randwrite / iodepth=32 / numjobs=4 / direct=1 / runtime=120s`

| 항목 | qcow2 (동적 할당) | Raw Mapping (물리 파티션) | 변화 |
|------|:-----------------:|:------------------------:|:----:|
| IOPS | 238,000 | **269,000** | **+13%** |
| Bandwidth | 932 MiB/s | **1,050 MiB/s** | **+12.6%** |
| 평균 Latency | 133.94 µs | **118.77 µs** | **-11%** |
| p99.99 Latency | 1,385 µs | **685 µs** | **-50.5%** |

**핵심 발견:** IOPS 개선(13%)보다 **Tail Latency 50% 감소**가 더 중요한 수확.  
qcow2의 L2 테이블 메타데이터 갱신이 불규칙한 I/O 스파이크를 유발하며, Raw Mapping으로 이를 완전히 제거.

> 상세 분석 → [docs/02_scenario1.md](docs/02_scenario1.md)

---

### Scenario 2: 쓰기 증폭(WAF) — Replica 2 vs 3

> fio 조건: `50MB/s Rate Limit 고정 쓰기 / iostat으로 물리 디스크 실측`

| Ceph 파라미터 | 클라이언트 쓰기 | 물리 NVMe 실측 쓰기 | WAF |
|:------------:|:--------------:|:------------------:|:---:|
| Replica 2 | 50 MiB/s | 205.63 MB/s | **약 3.7~4.1x** |
| Replica 3 | 50 MiB/s | 300.05 MB/s | **약 5.0~6.0x** |

**핵심 발견:** 이론값(Replica 3 → 3x WAF)보다 실측값이 5~6x로 높게 나옴.  
BlueStore의 WAL + RocksDB 이중 쓰기 구조가 복제 배수에 추가 오버헤드를 더함.  
가용성(HA)과 디스크 수명 간의 트레이드오프를 정량적으로 확인.

> 상세 분석 → [docs/03_scenario2.md](docs/03_scenario2.md)

---

### Scenario 3: I/O 파이프라인 병목 계층 분리

> fio 조건: `4K randwrite / ioengine=libaio / direct=1 / runtime=120s`

| 항목 | psync baseline | libaio baseline | libaio stress | baseline→stress 변화 |
|------|:--------------:|:---------------:|:-------------:|:--------------------:|
| iodepth × numjobs | 32×4 | 32×4 | 128×8 | Queue 128→1024 |
| IOPS | 1,591 | 8,709 | 9,811 | **+12.6%** |
| 평균 Latency | 2.5ms | 14.68ms | **104.29ms** | **+610%** |
| p99 Latency | 5.0ms | 32ms | **393ms** | **+1,128%** |
| slat (제출 지연) | - | 11.4µs | **801µs** | **+6,900%** |
| iostat w_await | 0.10ms | 0.07ms | **0.06ms** | **변화 없음** |
| NVMe %util | - | 12~22% | **10~20%** | **변화 없음** |
| ceph apply_lat | 0~1ms | 4~7ms | **5~11ms** | +57% |

**핵심 발견 1 — ioengine 효과:**  
psync(동기) → libaio(비동기) 전환만으로 IOPS 5.5배 향상.  
하드웨어 변경 없이 I/O 엔진 선택이 성능을 결정.

**핵심 발견 2 — 병목 위치:**  
극한 부하에서 NVMe는 끝까지 여유(w_await 0.06ms, %util 20%).  
병목은 물리 디스크가 아니라 **Ceph OSD 소프트웨어 처리 큐**.

**핵심 발견 3 — Little's Law 검증:**
```
Latency = Queue Depth / Throughput

Baseline:  128 ÷ 8,709  = 14.7ms  (실측 14.68ms ✓)
Stress:   1024 ÷ 9,811  = 104.4ms  (실측 104.29ms ✓)
```
수식과 실측값이 일치 → 노이즈 없는 측정 환경 검증.

> 상세 분석 → [docs/04_scenario3.md](docs/04_scenario3.md)

---

## 5. 핵심 발견

| # | 발견 | 근거 |
|---|------|------|
| 1 | Raw Mapping은 IOPS보다 Tail Latency 안정성에 더 큰 효과 | p99.99 50% 감소 |
| 2 | Ceph WAF는 이론 복제 배수보다 높다 (BlueStore 이중 쓰기) | Replica3 실측 5~6x vs 이론 3x |
| 3 | 동기(psync) I/O 엔진이 성능의 최대 병목이 될 수 있음 | IOPS 5.5배 차이 |
| 4 | 단일 스핀들 HCI에서 병목은 NVMe가 아닌 Ceph 소프트웨어 큐 | w_await 불변, slat 70배 증가 |
| 5 | Little's Law로 Ceph I/O 동작을 정량 예측 가능 | 수식 ↔ 실측값 일치 |

---

## 6. 트러블슈팅

구축 과정에서 발생한 주요 장애와 해결 과정을 기록.

| 장애 | 원인 | 해결 |
|------|------|------|
| Ceph MON 쿼럼 붕괴 | 중첩 가상화 환경 Clock Skew | chrony 강제 재동기화 |
| OSD 반복 다운 | KVM 가상 디스크 UUID 변경 | ceph-volume lvm 재활성화 |
| Kolla-Ansible 배포 실패 | NIC 브리지 하이재킹 | Multi-NIC 구성으로 망 분리 |

> 상세 기록 → [docs/05_troubleshooting.md](docs/05_troubleshooting.md)

---

## 7. 실험 재현

```bash
# 레포 클론
git clone https://github.com/kimseungO/ceph-openstack-performance-analysis.git
cd ceph-openstack-performance-analysis

# 시나리오별 실험 스크립트
bash scripts/bench_scenario1.sh   # qcow2 vs Raw Mapping
bash scripts/bench_scenario2.sh   # Write Amplification
bash scripts/bench_scenario3.sh   # I/O 파이프라인 병목 분석
```

> 환경 구축 절차 → [docs/01_architecture.md](docs/01_architecture.md)

---

## References

- [Ceph BlueStore 공식 문서](https://docs.ceph.com/en/latest/rados/configuration/bluestore-config-ref/)
- [OpenStack Cinder RBD 드라이버](https://docs.openstack.org/cinder/latest/configuration/block-storage/drivers/ceph-rbd-volume-driver.html)
- [Kolla-Ansible 배포 가이드](https://docs.openstack.org/kolla-ansible/latest/)
- [fio 공식 문서](https://fio.readthedocs.io/en/latest/)
- Little, J. D. C. (1961). "A Proof for the Queuing Formula: L = λW"

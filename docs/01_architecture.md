# 환경 구축 및 아키텍처 설계

## 목차

1. [전체 아키텍처 개요](#1-전체-아키텍처-개요)
2. [물리 인프라 구성](#2-물리-인프라-구성)
3. [네트워크 설계](#3-네트워크-설계)
4. [KVM 하이퍼바이저 구성](#4-kvm-하이퍼바이저-구성)
5. [Ceph 클러스터 구축](#5-ceph-클러스터-구축)
6. [OpenStack 배포](#6-openstack-배포)
7. [핵심 아키텍처 의사결정](#7-핵심-아키텍처-의사결정)

---

## 1. 전체 아키텍처 개요

단일 물리 서버 위에 KVM + OpenStack + Ceph를 수직으로 쌓은  
**HCI(Hyper-Converged Infrastructure)** 구성입니다.

```
┌─────────────────────────────────────────────────────────────────┐
│                   Xubuntu 22.04 (Bare-metal Host)               │
│                    Intel i5-12400 / 64GB / 1TB NVMe             │
│                                                                 │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌───────────┐  │
│  │ controller │  │  ubuntu01  │  │  ubuntu02  │  │  ubuntu03 │  │
│  │            │  │            │  │            │  │           │  │
│  │ OpenStack  │  │  Compute   │  │  Compute   │  │  Compute  │  │
│  │ Controller │  │  Ceph OSD  │  │  Ceph OSD  │  │  Ceph OSD │  │
│  │ Ceph MON   │  │            │  │            │  │           │  │
│  │ Ceph MGR   │  │ /dev/vdb   │  │ /dev/vdb   │  │ /dev/vdb  │  │
│  │            │  │ (Raw Map)  │  │ (Raw Map)  │  │ (Raw Map) │  │
│  └────────────┘  └─────┬──────┘  └─────┬──────┘  └─────┬─────┘  │
│                        │               │               │        │
│   Management Network: 192.168.0.0/24   │               │        │
│   Provider  Network: public1 (FIP)     │               │        │
│                        │               │               │        │
│              ┌─────────▼───────────────▼───────────────▼──────┐ │
│              │   nvme1n1p3       nvme1n1p4       nvme1n1p5    │ │
│              │              1TB NVMe SSD                      │ │
│              └────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### 레이어별 역할

| 레이어 | 구성요소 | 역할 |
|--------|----------|------|
| L1 물리 | Xubuntu 22.04 + KVM | 하이퍼바이저, NVMe Raw Mapping |
| L2 네트워크 | Linux Bridge + OVS | Management / Provider 망 분리 |
| L3 스토리지 | Ceph Quincy (cephadm) | 분산 블록 스토리지 |
| L4 클라우드 | OpenStack Caracal (Kolla-Ansible) | IaaS 컨트롤 플레인 |

---

## 2. 물리 인프라 구성

### 호스트 사양

| 항목 | 사양 |
|------|------|
| CPU | Intel Core i5-12400 (6C/12T, Alder Lake) |
| Memory | 64GB DDR4 Dual Channel (32GB × 2) |
| Storage | 1TB NVMe SSD (nvme1n1) |
| Host OS | Xubuntu 22.04 LTS |
| Hypervisor | KVM (libvirt) |

### NVMe 파티션 구성

```
nvme1n1 (1TB)
├── nvme1n1p1    487MB    /boot/efi
├── nvme1n1p2    488.3GB  /  (호스트 OS)
├── nvme1n1p3    100GB    → ubuntu01 OSD Raw Mapping
├── nvme1n1p4    100GB    → ubuntu02 OSD Raw Mapping
└── nvme1n1p5    100GB    → ubuntu03 OSD Raw Mapping
```

### VM 리소스 할당

| 노드 | vCPU | RAM | OS 디스크 | 데이터 디스크 | IP |
|------|:----:|:---:|:---------:|:------------:|:--:|
| controller | 2 | 12GB | 100GB (qcow2) | - | 192.168.0.11 |
| ubuntu01 | 2 | 12GB | 50GB (qcow2) | nvme1n1p3 (Raw) | 192.168.0.12 |
| ubuntu02 | 2 | 12GB | 50GB (qcow2) | nvme1n1p4 (Raw) | 192.168.0.13 |
| ubuntu03 | 2 | 12GB | 50GB (qcow2) | nvme1n1p5 (Raw) | 192.168.0.14 |

> 총 RAM 사용: 48GB (VM) + 호스트 OS = 64GB 풀 활용

---

## 3. 네트워크 설계

### 망 분리 구성

두 네트워크를 논리적으로 분리하여 관리 트래픽과 데이터 트래픽을 격리합니다.

```
┌─────────────────────────────────────────┐
│  Management Network (192.168.0.0/24)    │
│  - 노드 간 API 통신                      │
│  - Ceph 클러스터 내부 통신                │
│  - Kolla-Ansible 배포 통신               │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│  Provider Network (public1)             │
│  - Floating IP 할당 및 외부 라우팅       │
│  - OpenStack 인스턴스 외부 통신          │
└─────────────────────────────────────────┘
```

### NIC 구성

브리지 네트워크에 바인딩된 물리 NIC가 Down 상태가 되어  
Floating IP 통신이 차단되는 장애를 경험했습니다.

이를 방지하기 위해 **Multi-NIC 구성**으로 Management와 Provider 망을  
별도 물리 인터페이스에 바인딩했습니다.

```bash
# Provider 네트워크 인터페이스 활성화
ip link set enp7s0 up
ip link set enp8s0 up
```

> 관련 트러블슈팅 → [docs/05_troubleshooting.md #3](05_troubleshooting.md)

---

## 4. KVM 하이퍼바이저 구성

### Raw Device Mapping 적용

OSD VM의 데이터 디스크를 qcow2가 아닌 물리 파티션으로 직접 연결합니다.

```bash
# ubuntu01에 nvme1n1p3 Raw Mapping
virt-install \
  --name ubuntu01 \
  --disk /var/lib/libvirt/images/ubuntu01.qcow2,size=50 \
  --disk /dev/nvme1n1p3,bus=virtio,cache=none,io=native \
  ...
```

qcow2 대비 Raw Mapping의 성능 효과는 Scenario 1에서 정량적으로 측정했습니다.

| 지표 | 개선 효과 |
|------|-----------|
| IOPS | +13% |
| Tail Latency (p99.99) | **-50.5%** |

> 상세 분석 → [docs/02_scenario1.md](02_scenario1.md)

### 중첩 가상화(Nested Virtualization) 주의사항

KVM 위에서 VM을 실행하는 구조는 CPU 스케줄링 지연을 유발합니다.  
이로 인해 VM 간 시간 동기화(Clock Skew)가 발생하여  
Ceph MON 쿼럼이 불안정해질 수 있습니다.

```bash
# VM 내부에서 NTP 강제 동기화
chronyc makestep
systemctl restart chronyd
```

> 관련 트러블슈팅 → [docs/05_troubleshooting.md #1](05_troubleshooting.md)

---

## 5. Ceph 클러스터 구축

### 배포 방식: cephadm

Kolla-Ansible 내장 Ceph 배포 모듈 대신 **cephadm을 독립 배포**했습니다.

```
Kolla-Ansible 내장 모듈 사용 시:
- OpenStack 배포 라이프사이클에 Ceph가 종속됨
- Ceph 버전 업그레이드 시 OpenStack 재배포 필요

cephadm 독립 배포 시:
- Compute 노드 증설과 OSD 노드 확장을 독립적으로 수행 가능
- Ceph 클러스터 운영이 OpenStack 배포와 분리됨
```

### 클러스터 토폴로지

```
MON: 4개 (controller, ubuntu01, ubuntu02, ubuntu03)
MGR: Active(controller) + Standby(ubuntu01, ubuntu03)
OSD: 3개 (ubuntu01, ubuntu02, ubuntu03) - BlueStore 엔진
```

### 스토리지 풀 구성

OpenStack 서비스별로 풀을 분리하여 접근 권한을 최소화합니다.

```bash
# 풀 생성
ceph osd pool create volumes 64    # Cinder 블록 스토리지
ceph osd pool create images  32    # Glance 이미지
ceph osd pool create vms     64    # Nova 인스턴스 디스크

# 서비스별 키링 분리 발급 (최소 권한 원칙)
ceph auth get-or-create client.cinder \
    mon 'profile rbd' \
    osd 'profile rbd pool=volumes, profile rbd pool=vms'

ceph auth get-or-create client.glance \
    mon 'profile rbd' \
    osd 'profile rbd pool=images'

ceph auth get-or-create client.nova \
    mon 'profile rbd' \
    osd 'profile rbd pool=vms'
```

### 클러스터 정상 상태 확인

```bash
$ ceph -s
  cluster:
    health: HEALTH_OK
  services:
    mon: 4 daemons, quorum controller,ubuntu01,ubuntu02,ubuntu03
    mgr: controller(active), standbys: ubuntu01, ubuntu03
    osd: 3 osds: 3 up, 3 in
  data:
    pools: 4 pools, 97 pgs
    pgs: 97 active+clean
```

---

## 6. OpenStack 배포

### 배포 도구: Kolla-Ansible

컨테이너 기반 마이크로서비스 방식으로 OpenStack을 배포합니다.  
각 서비스가 독립 컨테이너로 실행되어 장애 격리와 업그레이드가 용이합니다.

```bash
# 배포 순서
kolla-ansible -i multinode bootstrap-servers
kolla-ansible -i multinode prechecks
kolla-ansible -i multinode deploy
```

### 활성화 서비스

| 서비스 | 역할 |
|--------|------|
| Keystone | Identity / 인증 |
| Glance | Image (Ceph RBD 백엔드) |
| Nova | Compute |
| Neutron | Network (OVS) |
| Cinder | Block Storage (Ceph RBD 백엔드) |
| Horizon | Dashboard |

### Ceph RBD 백엔드 연동

`globals.yml` 핵심 설정:

```yaml
# Ceph 백엔드 활성화
cinder_backend_ceph: "yes"
glance_backend_ceph: "yes"
nova_backend_ceph: "yes"

# 단일 디스크 환경에서 백업 비활성화
# (원본/백업이 동일 디스크 → DR 의미 없음)
enable_cinder_backup: "no"

# Ceph 클러스터 정보
ceph_cluster_fsid: "26705e26-3eae-11f1-840d-9f56d12533de"
ceph_external_mon_host: "192.168.0.11,192.168.0.12,192.168.0.13,192.168.0.14"
```

> `enable_cinder_backup: "no"` 누락으로 인한 배포 실패 경험  
> → [docs/05_troubleshooting.md #2](05_troubleshooting.md)

---

## 7. 핵심 아키텍처 의사결정

### 결정 1: Raw Mapping vs qcow2

**선택:** OSD 데이터 디스크에 Raw Mapping 적용

**근거:** qcow2의 L2 테이블 메타데이터 갱신이 불규칙한 I/O 스파이크(Tail Latency)를 유발합니다. OSD처럼 지속적인 쓰기가 발생하는 서비스에서 Tail Latency 안정성은 평균 IOPS보다 중요한 지표입니다.

**효과:** p99.99 Tail Latency 50.5% 감소

---

### 결정 2: cephadm vs Kolla 내장 Ceph 모듈

**선택:** cephadm 독립 배포

**근거:** OpenStack과 Ceph의 배포 라이프사이클을 분리하여 각각 독립적으로 확장·운영할 수 있도록 설계했습니다. Kolla 내장 모듈은 구형 Ceph 버전에 종속되는 문제도 있습니다.

---

### 결정 3: enable_cinder_backup 비활성화

**선택:** `enable_cinder_backup: "no"`

**근거:** 단일 물리 디스크 환경에서 원본과 백업을 동일 디스크에 저장하는 것은 DR 목적에 부합하지 않습니다. 불필요한 데몬을 명시적으로 비활성화하여 리소스를 절약합니다.

---

### 결정 4: 서비스별 Ceph 키링 분리

**선택:** client.cinder / client.glance / client.nova 각각 발급

**근거:** 최소 권한 원칙(Principle of Least Privilege) 적용. Glance가 침해되어도 Cinder 풀에는 접근 불가능한 구조를 설계했습니다.

← [README로 돌아가기](../README.md)

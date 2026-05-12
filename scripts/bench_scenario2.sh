#!/bin/bash
# =============================================================================
# Scenario 2: 쓰기 증폭(WAF) — Replica 2 vs 3
#
# 실행 위치:
#   - fio       → bench-vm (OpenStack 인스턴스)
#   - iostat    → 호스트(Xubuntu) — 별도 터미널에서 수동 실행
#   - pool 변경 → controller 노드 — 별도 터미널에서 수동 실행
#
# 전제 조건:
#   - bench-vm에 Cinder RBD 볼륨(/dev/vdb)이 연결된 상태
#   - fio 설치 완료
#
# 목적:
#   클라이언트 쓰기 속도를 고정(Rate Limit)한 상태에서
#   Replica 정책 변화에 따른 물리 디스크 실제 쓰기량(WAF) 측정
#
# 측정 방법:
#   WAF = iostat wkB/s (물리 디스크) / fio BW (클라이언트)
#
# 주의:
#   iostat은 호스트에서 별도 터미널로 동시에 실행해야 합니다.
#   아래 명령어를 호스트 터미널에서 fio 실행 전에 미리 시작하세요.
#   $ iostat -x 1 nvme1n1p3 nvme1n1p4 nvme1n1p5 | tee results/iostat_s2_replica3.log
# =============================================================================

set -e

RESULT_DIR="./results"
mkdir -p "$RESULT_DIR"

FIO_COMMON="--ioengine=libaio --iodepth=32 --rw=write --bs=4k \
            --direct=1 --size=1G --numjobs=1 \
            --runtime=60 --time_based --rate=50m --group_reporting"

TARGET="/dev/vdb"

echo "========================================"
echo " 사전 확인: 현재 Replica 정책"
echo " (controller에서 실행: ceph osd pool get volumes size)"
echo "========================================"
echo ""
echo "[주의] Replica 3 측정 전 controller에서 아래 확인:"
echo "  $ ceph osd pool get volumes size"
echo "  $ ceph osd pool get vms size"
echo ""
read -p "Replica 3 설정 확인 완료? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "중단합니다. controller에서 Replica 설정을 확인하세요."
    exit 1
fi

echo ""
echo "========================================"
echo " Scenario 2-A: Replica 3 WAF 측정"
echo " 클라이언트 쓰기: 50 MiB/s 고정"
echo " 호스트에서 iostat 동시 실행 필요"
echo "========================================"
echo ""
echo "[호스트 터미널에서 먼저 실행]"
echo "  $ iostat -x 1 nvme1n1p3 nvme1n1p4 nvme1n1p5 | tee results/iostat_s2_replica3.log"
echo ""
read -p "iostat 시작 확인 후 Enter: "

fio --name=write_amp \
    $FIO_COMMON \
    --filename="$TARGET" \
    --output="$RESULT_DIR/result_s2_replica3.txt"

echo ""
echo "========================================"
echo " Replica 2로 전환"
echo " controller에서 아래 명령어 실행 후 Enter:"
echo "   $ ceph osd pool set volumes size 2"
echo "   $ ceph osd pool set vms size 2"
echo "   $ ceph osd pool set images size 2"
echo "   $ ceph -s  # active+clean 확인"
echo "========================================"
echo ""
read -p "Replica 2 전환 및 클러스터 안정화 확인 후 Enter: "

echo ""
echo "========================================"
echo " Scenario 2-B: Replica 2 WAF 측정"
echo " 클라이언트 쓰기: 50 MiB/s 고정"
echo " 호스트에서 iostat 동시 실행 필요"
echo "========================================"
echo ""
echo "[호스트 터미널에서 먼저 실행]"
echo "  $ iostat -x 1 nvme1n1p3 nvme1n1p4 nvme1n1p5 | tee results/iostat_s2_replica2.log"
echo ""
read -p "iostat 시작 확인 후 Enter: "

fio --name=write_amp2 \
    $FIO_COMMON \
    --filename="$TARGET" \
    --output="$RESULT_DIR/result_s2_replica2.txt"

echo ""
echo "========================================"
echo " [중요] 실험 후 Replica 3으로 복원"
echo " controller에서 실행:"
echo "   $ ceph osd pool set volumes size 3"
echo "   $ ceph osd pool set vms size 3"
echo "   $ ceph osd pool set images size 3"
echo "========================================"
echo ""
echo "========================================"
echo " 결과 요약"
echo "========================================"

echo "[Replica 3] fio BW:"
grep "bw=" "$RESULT_DIR/result_s2_replica3.txt" | head -3

echo ""
echo "[Replica 2] fio BW:"
grep "bw=" "$RESULT_DIR/result_s2_replica2.txt" | head -3

echo ""
echo "원본 결과 파일:"
echo "  $RESULT_DIR/result_s2_replica3.txt"
echo "  $RESULT_DIR/result_s2_replica2.txt"
echo "  $RESULT_DIR/iostat_s2_replica3.log  (호스트에서 수집)"
echo "  $RESULT_DIR/iostat_s2_replica2.log  (호스트에서 수집)"

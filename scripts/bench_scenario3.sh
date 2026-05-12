#!/bin/bash
# =============================================================================
# Scenario 3: I/O 파이프라인 병목 계층 분리 분석
#
# 실행 위치: bench-vm (OpenStack 인스턴스)
#
# 전제 조건:
#   - bench-vm에 Cinder RBD 볼륨(/dev/vdb)이 연결된 상태
#   - fio 설치 완료
#   - 터미널 4개 준비 (동시 관측용)
#
# 목적:
#   동일한 워크로드 하에서 Baseline(iodepth=32×4)과 Stress(iodepth=128×8)를
#   비교하여 I/O 병목이 어느 레이어에서 발생하는지 계층별로 분리 진단
#
# 동시 관측 (별도 터미널에서 fio 실행 전에 미리 시작):
#   [controller 터미널 A] $ watch -n 1 'ceph osd perf'
#   [controller 터미널 B] $ watch -n 1 'ceph -s'
#   [호스트 터미널]        $ iostat -x 1 nvme1n1p3 nvme1n1p4 nvme1n1p5 | tee results/iostat_s3.log
#
# 핵심 관측 포인트:
#   Stress 단계에서 아래 순서로 수치가 변화하는지 확인:
#   1. iostat w_await 상승  (물리 디스크 포화 신호)
#   2. ceph osd perf apply_lat 상승  (OSD 레이어 전파)
#   3. fio latency 상승  (클라이언트 레이어 전파)
# =============================================================================

set -e

RESULT_DIR="./results"
mkdir -p "$RESULT_DIR"

TARGET="/dev/vdb"

FIO_COMMON="--filename=$TARGET --direct=1 --ioengine=libaio \
            --rw=randwrite --bs=4k \
            --runtime=120 --time_based --group_reporting"

echo "========================================"
echo " 사전 확인: 동시 관측 도구 실행 여부"
echo "========================================"
echo ""
echo "[controller 터미널 A에서 실행]"
echo "  $ watch -n 1 'ceph osd perf'"
echo ""
echo "[controller 터미널 B에서 실행]"
echo "  $ watch -n 1 'ceph -s'"
echo ""
echo "[호스트 터미널에서 실행]"
echo "  $ iostat -x 1 nvme1n1p3 nvme1n1p4 nvme1n1p5 | tee results/iostat_s3_baseline.log"
echo ""
read -p "3개 터미널 관측 시작 확인 후 Enter: "

echo ""
echo "========================================"
echo " Scenario 3-A: Baseline"
echo " iodepth=32 / numjobs=4 / Queue Depth=128"
echo " 런타임: 120초"
echo "========================================"

fio --name=baseline \
    $FIO_COMMON \
    --iodepth=32 \
    --numjobs=4 \
    --output="$RESULT_DIR/result_s3_baseline.txt"

echo ""
echo "Baseline 완료. 호스트 iostat 로그를 저장하고 새 로그로 재시작하세요."
echo ""
echo "[호스트 터미널에서 재시작]"
echo "  Ctrl+C 후: $ iostat -x 1 nvme1n1p3 nvme1n1p4 nvme1n1p5 | tee results/iostat_s3_stress.log"
echo ""
read -p "iostat 재시작 확인 후 Enter: "

echo ""
echo "========================================"
echo " Scenario 3-B: Stress"
echo " iodepth=128 / numjobs=8 / Queue Depth=1,024"
echo " 런타임: 120초"
echo ""
echo " [관측 포인트]"
echo "   ceph osd perf apply_lat 상승 여부"
echo "   iostat w_await / %%util 변화"
echo "========================================"

fio --name=stress \
    $FIO_COMMON \
    --iodepth=128 \
    --numjobs=8 \
    --output="$RESULT_DIR/result_s3_stress.txt"

echo ""
echo "========================================"
echo " 결과 요약 및 Little's Law 검증"
echo "========================================"

echo "[Baseline]"
grep -E "IOPS=|lat " "$RESULT_DIR/result_s3_baseline.txt" | head -4

echo ""
echo "[Stress]"
grep -E "IOPS=|lat " "$RESULT_DIR/result_s3_stress.txt" | head -4

echo ""
echo "---------------------------------------"
echo " Little's Law 검증: Latency = Queue Depth / IOPS"
echo ""

BASELINE_IOPS=$(grep "iops" "$RESULT_DIR/result_s3_baseline.txt" | grep "avg=" | \
    sed 's/.*avg=\([0-9.]*\).*/\1/' | head -1)
STRESS_IOPS=$(grep "iops" "$RESULT_DIR/result_s3_stress.txt" | grep "avg=" | \
    sed 's/.*avg=\([0-9.]*\).*/\1/' | head -1)

echo " Baseline 예측 Latency = 128 / $BASELINE_IOPS"
echo " Stress   예측 Latency = 1024 / $STRESS_IOPS"
echo " (실측값과 비교: result 파일의 avg lat 확인)"
echo "---------------------------------------"
echo ""
echo "원본 결과 파일:"
echo "  $RESULT_DIR/result_s3_baseline.txt"
echo "  $RESULT_DIR/result_s3_stress.txt"
echo "  $RESULT_DIR/iostat_s3_baseline.log  (호스트에서 수집)"
echo "  $RESULT_DIR/iostat_s3_stress.log    (호스트에서 수집)"

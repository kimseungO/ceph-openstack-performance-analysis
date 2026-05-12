#!/bin/bash
# =============================================================================
# Scenario 1: 가상화 I/O 오버헤드 — qcow2 vs Raw Mapping
#
# 실행 위치: ubuntu01 (Compute + OSD 노드)
# 전제 조건:
#   - /dev/vdb : qcow2 기반 가상 디스크 (OS 디스크가 아닌 별도 데이터 디스크)
#   - /dev/vdc : 호스트 NVMe 물리 파티션 Raw Mapping 디스크
#   - fio 설치 완료 (apt install fio)
#
# 목적:
#   하이퍼바이저 디스크 레이어 방식(qcow2 vs Raw)이 I/O 성능에 미치는 영향 측정
#   유일한 변인: KVM 디스크 백엔드 방식 (나머지 조건 동일)
# =============================================================================

set -e

RESULT_DIR="./results"
mkdir -p "$RESULT_DIR"

FIO_COMMON="--ioengine=libaio --iodepth=32 --rw=randwrite --bs=4k \
            --direct=1 --size=1G --numjobs=1 \
            --runtime=60 --time_based --group_reporting"

echo "========================================"
echo " Scenario 1-A: qcow2 디스크 벤치마크"
echo " 대상: /dev/vdb (qcow2 기반 가상 디스크)"
echo "========================================"

fio --name=randwrite_qcow2 \
    $FIO_COMMON \
    --filename=/dev/vdb \
    --output="$RESULT_DIR/result_s1_qcow2.txt"

echo ""
echo "========================================"
echo " Scenario 1-B: Raw Mapping 디스크 벤치마크"
echo " 대상: /dev/vdc (NVMe 물리 파티션 직접 매핑)"
echo "========================================"

fio --name=randwrite_raw \
    $FIO_COMMON \
    --filename=/dev/vdc \
    --output="$RESULT_DIR/result_s1_raw.txt"

echo ""
echo "========================================"
echo " 결과 요약"
echo "========================================"

echo "[qcow2]"
grep -E "IOPS=|lat " "$RESULT_DIR/result_s1_qcow2.txt" | head -5

echo ""
echo "[Raw Mapping]"
grep -E "IOPS=|lat " "$RESULT_DIR/result_s1_raw.txt" | head -5

echo ""
echo "원본 결과 파일: $RESULT_DIR/result_s1_qcow2.txt"
echo "원본 결과 파일: $RESULT_DIR/result_s1_raw.txt"

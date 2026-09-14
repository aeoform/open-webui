#!/bin/bash
# ─────────────────────────────────────────────────────────────
# 在 x86-64-v1 (Intel Atom D525 / Bonnell) 机器上验证镜像
#   用法: bash bonnell-build/smoke-test-v1.sh [镜像名]
#   默认镜像: open-webui:bonnell
#
# 为什么要逐模块开子进程：SIGILL 会直接杀掉进程，无法在同一个
# Python 进程里 try/except 捕获。分开跑才能精确定位是哪个库崩。
# ─────────────────────────────────────────────────────────────
IMG="${1:-open-webui:bonnell}"
FAIL=0

echo "镜像: $IMG"
echo "本机 CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')"
V2=$(grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2 | tr ' ' '\n' | grep -cE '^(sse4_1|sse4_2|avx|avx2|fma|bmi1|bmi2|popcnt)$')
echo "本机 v2+ 特征数: $V2  (v1 机器应为 0，用来确认确实在旧 CPU 上跑)"

echo
echo "── 1) 逐模块导入（独立进程，能定位 SIGILL）──"
for m in numpy pyarrow tokenizers onnxruntime scipy sklearn pandas chromadb \
         soundfile av tiktoken PIL cryptography sqlalchemy ctranslate2 \
         transformers faster_whisper sentence_transformers torch; do
  docker run --rm --entrypoint python3 "$IMG" -c "import $m" >/dev/null 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    printf '   OK    %s\n' "$m"
  else
    rc_txt=""
    [ $rc -eq 132 ] && rc_txt=" ← SIGILL(4): 该库含本机不支持的指令"
    [ $rc -eq 139 ] && rc_txt=" ← SIGSEGV"
    printf '   FAIL  %s (rc=%s)%s\n' "$m" "$rc" "$rc_txt"
    FAIL=1
  fi
done

echo
echo "── 2) 真实执行 SIMD 计算内核（只 import 不会走到这些路径）──"
docker run --rm --entrypoint python3 "$IMG" - <<'PY' || FAIL=1
import numpy as np
a = np.random.rand(512, 512).astype('float32')
print('   numpy matmul     OK  sum=%.1f' % float((a @ a.T).sum()))

import pyarrow as pa, pyarrow.parquet as pq, tempfile, os
f = os.path.join(tempfile.mkdtemp(), 't.parquet')
pq.write_table(pa.table({'x': list(range(1000))}), f)
print('   pyarrow parquet  OK  rows=%d' % pq.read_table(f).num_rows)

import tiktoken
print('   tiktoken         OK  tokens=%d' % len(tiktoken.get_encoding('cl100k_base').encode('hello 世界')))

import torch
print('   torch matmul     OK  sum=%.1f' % float((torch.ones(256, 256) @ torch.ones(256, 256)).sum()))

import onnxruntime as ort
print('   onnxruntime      OK  %s (MLAS 运行时分发)' % ort.__version__)

from tokenizers import Tokenizer
print('   tokenizers       OK  (Rust is_x86_feature_detected 保护)')
PY

echo
echo "── 3) 启动自检 ──"
docker rm -f owui-smoke >/dev/null 2>&1
docker run -d --name owui-smoke -p 18080:8080 "$IMG" >/dev/null
for i in $(seq 1 24); do
  st=$(docker inspect -f '{{.State.Health.Status}}' owui-smoke 2>/dev/null)
  [ "$st" = healthy ] && break
  [ "$st" = unhealthy ] && break
  sleep 15
done
echo "   health: $st"
curl -s --max-time 10 http://localhost:18080/api/version && echo
docker logs owui-smoke 2>&1 | grep -iE "traceback|illegal instruction|ImportError" | head -5
docker rm -f owui-smoke >/dev/null 2>&1

echo
[ $FAIL -eq 0 ] && echo "结论: 全部通过 ✅  该镜像可以在本机运行" || echo "结论: 有失败项 ❌  见上面标记"
exit $FAIL

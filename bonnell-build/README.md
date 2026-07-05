# Bonnell (x86-64-v1) 镜像构建指南

## 背景

Intel Atom D525（Bonnell 微架构）只支持到 SSSE3，不支持 SSE4.x/AVX。
Open WebUI 的 manylinux 预编译包默认要求 x86-64-v2（SSE4.2），在 Bonnell 上会 SIGILL 崩溃。

## 整体策略

- **4 个包源码重建**：numpy、pyarrow、tokenizers、onnxruntime — 这些无法用运行时环境变量完全控制 SIMD
- **其余包用 manylinux wheel**：scipy、sklearn、opencv、ctranslate2 等通过运行时环境变量控制 SIMD dispatch
- **Arrow C++ .so 直接拷贝**：pyarrow 依赖的 libarrow 库从 builder 镜像复制到最终镜像
- **每个依赖独立编译容器**：互不影响，某一个失败不需要重头再来

## 文件结构

```
bonnell-build/
├── Dockerfile.build-numpy       # 独立编译 numpy
├── Dockerfile.build-pyarrow     # 独立编译 Arrow C++ + pyarrow
├── Dockerfile.build-tokenizers  # 独立编译 tokenizers
├── Dockerfile.build-onnxruntime # 独立编译 onnxruntime
├── README.md                    # 本文档
├── bonnell-wheels/              # 编译产物: 所有 .whl 文件
└── arrow-libs/                  # 从 pyarrow builder 拷出的 libarrow.so 等运行时库
```

## 构建步骤

每个 Dockerfile 都是独立容器，可以按任意顺序构建。推荐先跑 numpy 和 tokenizers（快），再跑 pyarrow（中等），最后跑 onnxruntime（最慢，~1-2h）。

### 1. 构建 numpy

```bash
docker build --network=host --no-cache \
  -t bonnell-build-numpy \
  -f bonnell-build/Dockerfile.build-numpy \
  bonnell-build/
```

导出 wheel：

```bash
ctr=$(docker create bonnell-build-numpy)
mkdir -p bonnell-build/bonnell-wheels
docker cp $ctr:/build/wheels/. bonnell-build/bonnell-wheels/
docker rm $ctr
```

### 2. 构建 pyarrow

```bash
docker build --network=host --no-cache \
  -t bonnell-build-pyarrow \
  --build-arg ARROW_VERSION=20.0.0 \
  -f bonnell-build/Dockerfile.build-pyarrow \
  bonnell-build/
```

导出 wheel + Arrow 运行时库：

```bash
ctr=$(docker create bonnell-build-pyarrow)
mkdir -p bonnell-build/bonnell-wheels bonnell-build/arrow-libs
docker cp $ctr:/build/wheels/. bonnell-build/bonnell-wheels/
docker cp $ctr:/build/arrow-libs/. bonnell-build/arrow-libs/
docker rm $ctr
```

### 3. 构建 tokenizers

```bash
docker build --network=host --no-cache \
  -t bonnell-build-tokenizers \
  -f bonnell-build/Dockerfile.build-tokenizers \
  bonnell-build/
```

导出 wheel：

```bash
ctr=$(docker create bonnell-build-tokenizers)
mkdir -p bonnell-build/bonnell-wheels
docker cp $ctr:/build/wheels/. bonnell-build/bonnell-wheels/
docker rm $ctr
```

### 4. 构建 onnxruntime

这是最慢的构建（~1-2h），但独立于其他三个。

```bash
docker build --network=host --no-cache \
  -t bonnell-build-onnxruntime \
  --build-arg ORT_VERSION=1.26.0 \
  -f bonnell-build/Dockerfile.build-onnxruntime \
  bonnell-build/
```

导出 wheel：

```bash
ctr=$(docker create bonnell-build-onnxruntime)
mkdir -p bonnell-build/bonnell-wheels
docker cp $ctr:/build/wheels/. bonnell-build/bonnell-wheels/
docker rm $ctr
```

### 5. 验证 wheel 无 SSE4/AVX 指令

```bash
# numpy / pyarrow / onnxruntime — 期望 0 条 AVX 指令
for whl in bonnell-build/bonnell-wheels/*.whl; do
  echo "=== $(basename $whl) ==="
  tmpdir=$(mktemp -d) && cd "$tmpdir"
  unzip -q "$OLDPWD/$whl"
  find . -name "*.so" -exec sh -c \
    'count=$(objdump -d {} | grep -cE "vpcmpeq|vzeroupper|pinsrq"); echo "  {}: $count"' \;
  cd "$OLDPWD" && rm -rf "$tmpdir"
done

# tokenizers — Rust 编译带 target-cpu=x86-64
# 仍有 ~600 条 AVX 指令，但由 is_x86_feature_detected!() 运行时保护，Bonnell 不会触发
```

### 6. 确认导出产物

```bash
ls -lh bonnell-build/bonnell-wheels/
# 期望看到: numpy-*.whl  pyarrow-*.whl  tokenizers-*.whl  onnxruntime-*.whl

ls -lh bonnell-build/arrow-libs/libarrow*.so
# 期望看到: libarrow.so, libparquet.so 等
```

### 7. 构建最终镜像

```bash
docker build --network=host -t open-webui:bonnell \
  --build-arg USE_CUDA=false --build-arg USE_OLLAMA=false \
  -f Dockerfile .
```

> 注意：主 Dockerfile 的 Bonnell 段使用 glob 匹配 wheel 文件名
> (`numpy-*.whl`, `pyarrow-*.whl` 等)，所以版本号变化不需要改 Dockerfile。

### 8. 验证

```bash
# 导入检查
docker run --rm --entrypoint python3 open-webui:bonnell -c "
import numpy,pyarrow,tokenizers,onnxruntime,scipy,sklearn,cv2,sentencepiece,pandas,faster_whisper
print('All imports OK')
"

# 启动测试
docker run -d --name test -p 8080:8080 open-webui:bonnell
# 等 2-3 分钟后 docker ps 应显示 (healthy)

# 清理
docker stop test && docker rm test
```

## 版本升级注意事项

| 组件 | 需检查 | 说明 |
|---|---|---|
| Python 版本 | 所有 `Dockerfile.build-*` 的 `BASE_IMAGE` arg 必须与主 Dockerfile base 一致 | 当前 `python:3.11.14-slim-bookworm` |
| Arrow C++ | `Dockerfile.build-pyarrow` 的 `ARROW_VERSION` build arg | 必须与 requirements.txt 中 pyarrow 版本一致 |
| onnxruntime | `Dockerfile.build-onnxruntime` 的 `ORT_VERSION` build arg | 必须与 requirements.txt 中 onnxruntime 版本一致 |
| numpy / tokenizers | 不锁定版本，自动构建最新兼容版 | 主 Dockerfile 用 glob 匹配，无需修改 |
| wheel 文件名中的 `cp311` | Python 大版本变了要更新 | 如 Python 3.12 → `cp312` |
| 运行时库包名 | `libre2-9`、`libthrift-0.17.0` | Debian bookworm 的 `apt-cache search` 检查 |
| pyarrow `__version__ = None` 修复 | 自动从 wheel 文件名提取版本并 sed | 如果 Arrow 修了 shallow clone 版本问题可去除此段 |

## 运行时 SIMD 控制总结

| 环境变量 | 控制范围 | Bonnell 设置 |
|---|---|---|
| `OPENBLAS_CORETYPE` | OpenBLAS（scipy/numpy 的 BLAS） | `BONNELL` |
| `ARROW_USER_SIMD_LEVEL` | Arrow C++ CPU dispatch | `NONE` |
| `OPENCV_CPU_DISABLE` | OpenCV 多架构 dispatch | `AVX2,AVX,SSE4.2,SSE4.1,SSSE3,SSE3` |
| `NPY_DISABLE_CPU_FEATURES` | numpy CPU feature 检测 | `AVX,AVX2,AVX512F,FMA3,FMA4,SSE4_1,SSE4_2,POPCNT` |
| Rust `is_x86_feature_detected!` | tokenizers, chromadb, hf_xet 等 | 运行时自动检测，Bonnell 回退 scalar |

## 已移除的无引用依赖

以下依赖在上游 `requirements.txt` 中存在，但代码中零 import，已从我们的版本中移除：

| 依赖 | 说明 |
|---|---|
| `APScheduler` | 代码无任何 import |
| `RestrictedPython` | 代码无任何 import |
| `rapidocr-onnxruntime` | 代码无任何 import，onnxruntime 保留（chromadb 硬依赖） |

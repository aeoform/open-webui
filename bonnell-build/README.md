# Bonnell (x86-64-v1) 镜像构建指南

## 背景

Intel Atom D525（Bonnell 微架构）只支持到 SSSE3，不支持 SSE4.x/AVX。
Open WebUI 的 manylinux 预编译包默认要求 x86-64-v2（SSE4.2），在 Bonnell 上会 SIGILL 崩溃。

## 整体策略

- **3 个包源码重建**：numpy、pyarrow、tokenizers — 这三者无法用运行时环境变量完全控制 SIMD
- **其余包用 manylinux wheel**：scipy、sklearn、opencv、ctranslate2 等通过运行时环境变量控制 SIMD dispatch
- **Arrow C++ .so 直接拷贝**：pyarrow 依赖的 libarrow 库从 builder 镜像复制到最终镜像

## 文件结构

```
bonnell-build/
├── Dockerfile.wheel-builder    # 在 python:3.11-slim-bookworm 内编译 wheel
├── Dockerfile                  # Open WebUI 主 Dockerfile（含 Bonnell 段）
├── README.md                   # 本文档
├── bonnell-wheels/             # 编译产物: numpy, pyarrow, tokenizers 的 .whl
└── arrow-libs/                 # 从 builder 拷出的 libarrow.so 等运行时库
```

## 构建步骤

### 1. 构建 wheel-builder 镜像

```bash
docker build --network=host --no-cache -t bonnell-wheel-builder \
  -f bonnell-build/Dockerfile.wheel-builder \
  bonnell-build/
```

镜像内部做的事（`Dockerfile.wheel-builder`）：
- apt 安装编译依赖（g++、cmake、ninja、OpenBLAS、re2、thrift 等）
- 安装 Rust（tokenizers 需要）
- 从源码编译 **Arrow C++ 18.1.0**：
  - `-DARROW_SIMD_LEVEL=NONE`
  - `-DARROW_RUNTIME_SIMD_LEVEL=NONE`
  - `-DCMAKE_CXX_FLAGS="-march=x86-64 -mtune=generic -O2"`
- Arrow C++ 和 pyarrow 在同一个 RUN 中编译（pyarrow 需要 Arrow 源码树 + `PYARROW_CMAKE_OPTIONS="-DARROW_SIMD_LEVEL=NONE"`）
- 从源码编译 **numpy**：`-Dcpu-baseline=none -Ddisable-optimization=true`
- 从源码编译 **tokenizers**：`CARGO_BUILD_RUSTFLAGS="-C target-cpu=x86-64"`
  - tokenizers 的 AVX 代码由 `is_x86_feature_detected!("avx2")` 运行时保护，Bonnell 不会调用

### 2. 导出编译产物

```bash
# 导出 wheel
ctr=$(docker create bonnell-wheel-builder)
sudo rm -rf bonnell-build/bonnell-wheels && mkdir -p bonnell-build/bonnell-wheels
docker cp $ctr:/build/wheels/. bonnell-build/bonnell-wheels/
docker rm $ctr

# 导出 Arrow C++ 运行时库（.so files）
ctr=$(docker create bonnell-wheel-builder)
sudo rm -rf bonnell-build/arrow-libs && mkdir -p bonnell-build/arrow-libs
docker cp $ctr:/usr/local/lib/. bonnell-build/arrow-libs/
docker rm $ctr
```

### 3. 验证 wheel 无 SSE4/AVX 指令

```bash
# numpy
unzip -q bonnell-build/bonnell-wheels/numpy*.whl && \
  objdump -d numpy/_core/_multiarray_umath*.so | grep -cE "vpcmpeq|vzeroupper|pinsrq"
# 期望: 0

# pyarrow
unzip -q bonnell-build/bonnell-wheels/pyarrow*.whl && \
  find . -name "*.so" -exec sh -c 'objdump -d {} | grep -cE "vpcmpeq|vzeroupper|pinsrq"' \;
# 期望: 全部 0

# tokenizers — Rust 编译带 target-cpu=x86-64
# 仍有 ~612 条 AVX 指令，但由 is_x86_feature_detected! 运行时保护
```

### 4. Dockerfile Bonnell 段

位于 `uv pip install -r requirements.txt` 之后，核心逻辑：

```dockerfile
# 拷贝 Bonnell wheel
COPY --chown=$UID:$GID ./bonnell-build/bonnell-wheels /tmp/bonnell-wheels

# 拷贝 Arrow C++ 运行时库
COPY --chown=$UID:$GID ./bonnell-build/arrow-libs /usr/local/lib

# 替换 numpy / pyarrow / tokenizers
RUN pip3 install --no-cache-dir --force-reinstall --no-deps \
    /tmp/bonnell-wheels/numpy-2.4.6-cp311-cp311-linux_x86_64.whl \
    /tmp/bonnell-wheels/pyarrow-18.1.0-cp311-cp311-linux_x86_64.whl \
    /tmp/bonnell-wheels/tokenizers-0.22.2-cp39-abi3-linux_x86_64.whl && \
    sed -i 's/__version__ = None/__version__ = "18.1.0"/' \
    /usr/local/lib/python3.11/site-packages/pyarrow/__init__.py && \
    rm -rf /tmp/bonnell-wheels && ldconfig

# 安装 libarrow 运行时依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas0 libre2-9 libthrift-0.17.0 libutf8proc2 && \
    rm -rf /var/lib/apt/lists/*

# 运行时 SIMD 环境变量
ENV OPENBLAS_CORETYPE="BONNELL" \
    ARROW_USER_SIMD_LEVEL="NONE" \
    OPENCV_CPU_DISABLE="AVX2,AVX,SSE4.2,SSE4.1,SSSE3,SSE3"
```

### 5. 构建最终镜像

```bash
docker build --network=host -t open-webui:bonnell \
  --build-arg USE_CUDA=false --build-arg USE_OLLAMA=false \
  -f Dockerfile .
```

### 6. 验证

```bash
# 导入检查
docker run --rm --entrypoint python3 open-webui:bonnell -c "
import numpy,pyarrow,tokenizers,scipy,sklearn,cv2,ctranslate2,sentencepiece,pandas,faster_whisper
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
| Python 版本 | `Dockerfile.wheel-builder` 基础镜像必须与 `Dockerfile` base 一致 | 当前都是 `python:3.11-slim-bookworm` |
| Arrow C++ | `Dockerfile.wheel-builder` 第 28 行 `--branch apache-arrow-X.X.X` | 与 requirements.txt 中 pyarrow 一致 |
| numpy/pyarrow/tokenizers 版本 | `Dockerfile.wheel-builder` 中 `pip wheel` 命令 + `Dockerfile` 中 wheel 文件名 | 与 requirements.txt 一致 |
| wheel 文件名中的 `cp311` | Python 大版本变了要更新 | 如 Python 3.12 → `cp312` |
| 运行时库包名 | `libre2-9`、`libthrift-0.17.0` | Debian bookworm 的 `apt-cache search` 检查 |
| pyarrow `__version__ = None` 修复 | sed 替换是否还有效 | 如果 Arrow 修了 shallow clone 版本问题可以去除此行 |

## 运行时 SIMD 控制总结

| 环境变量 | 控制范围 | Bonnell 设置 |
|---|---|---|
| `OPENBLAS_CORETYPE` | OpenBLAS（scipy/numpy 的 BLAS） | `BONNELL` |
| `ARROW_USER_SIMD_LEVEL` | Arrow C++ CPU dispatch | `NONE` |
| `OPENCV_CPU_DISABLE` | OpenCV 多架构 dispatch | `AVX2,AVX,SSE4.2,SSE4.1,SSSE3,SSE3` |
| Rust `is_x86_feature_detected!` | tokenizers, chromadb, hf_xet 等 | 运行时自动检测，Bonnell 回退 scalar |

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

## v0.11.3 升级记录（2026-09-14）

### 1. 前端构建必须放开 Node 堆上限

0.11.3 前端体积变大，`npm run build` 会在默认 V8 old-space 下 OOM：

```
#23 FATAL ERROR: Ineffective mark-compacts near heap limit Allocation failed
     - JavaScript heap out of memory
```

主 Dockerfile 里已把上游注释掉的那行启用（比上游的 4096 更宽）：

```dockerfile
ENV NODE_OPTIONS="--max-old-space-size=8192"
```

### 2. 依赖变化

| 项 | 变化 | 说明 |
|---|---|---|
| numpy / pyarrow / onnxruntime / tokenizers | **无变化** | 与 v0.11.0 完全一致，`bonnell-wheels/` 里的 wheel 直接复用，无需重编 |
| aiodns | 4.0.4 → 3.6.1 | 上游回退（4.x 的 pycares 5 在某些主机上解析 DNS 有问题），对 SIMD 无影响 |
| python-docx | 新增 | 纯 Python |
| 见下方「已移除的无引用依赖」 | 删除 8 个 | 全部为零引用且无人依赖的包 |

> 结论：本次镜像的**原生二进制集合与 v0.11.0 的 Bonnell 镜像相同**，x86-64-v1 兼容风险没有变化。

### 3. v1 兼容性（已在 Atom D525 实机验证通过）

本镜像已在 x86-64-v1 实机跑通。以下是当时用到的判定方法，以后升级要复查时照做：

**静态扫描**（`objdump` 反汇编镜像内所有 .so，统计 Bonnell 不支持的指令）：

```bash
docker run --rm --entrypoint bash open-webui:bonnell -c '
  apt-get update -qq && apt-get install -y -qq binutils >/dev/null 2>&1
  SP=/usr/local/lib/python3.11/site-packages
  find $SP -name "*.so*" -size +16k | while read f; do
    n=$(objdump -d "$f" | grep -cE "\bv[a-z][a-z0-9]*[[:space:]]|\b(popcnt|ptest|pcmpistri|crc32|crc32|pmulld|roundps|pinsrq|pextrq|andn|tzcnt|lzcnt|bzhi|mulx|pdep|rorx|sarx|shlx|movbe|aesenc|pclmulqdq)\b")
    [ "$n" != 0 ] && printf "%8s  %s\n" "$n" "${f#$SP/}"
  done | sort -rn | head -30'
```

实测结果：numpy / pyarrow = **0 条**（自己重编的）；tokenizers 有 AVX 但由 Rust
`is_x86_feature_detected!()` 运行时保护；其余含 v2 指令的库（torch / scipy /
blis / ctranslate2 / av / onnxruntime 等）均带 CPUID 运行时分发；rapidfuzz 的
`*_avx2.so` 是独立模块，v1 机器根本不会加载它。

**实机逐模块导入**：SIGILL 会直接杀掉进程、无法 try/except 捕获，所以必须**每个模块开一个独立进程**，靠退出码定位：

```bash
for m in numpy pyarrow tokenizers onnxruntime scipy sklearn pandas chromadb \
         torch transformers faster_whisper chromadb sentence_transformers; do
  docker run --rm --entrypoint python3 open-webui:bonnell -c "import $m" >/dev/null 2>&1
  echo "rc=$? $m"   # rc=132 即 SIGILL：该库含本机不支持的指令
  docker run --rm --entrypoint python3 open-webui:bonnell -c "import $m" 2>&1 | tail -1
done
```

注意：只 import 走不到 SIMD 内核，最好再真算一遍：

```bash
docker run --rm --entrypoint python3 open-webui:bonnell -c "
import numpy as np, torch, pyarrow as pa, pyarrow.parquet as pq, tempfile, os, tiktoken
print(float((np.random.rand(512,512).astype('float32') @ np.random.rand(512,512).astype('float32')).sum()))
print(float((torch.ones(256,256) @ torch.ones(256,256)).sum()))
f=os.path.join(tempfile.mkdtemp(),'t.parquet'); pq.write_table(pa.table({'x':list(range(1000))}), f)
print(pq.read_table(f).num_rows, len(tiktoken.get_encoding('cl100k_base').encode('hello 世界')))"
```

最后起容器确认 `/health` 与 `/api/version`：

```bash
docker run -d --name owui -p 8080:8080 open-webui:bonnell
docker inspect -f '{{.State.Health.Status}}' owui   # 首次启动要下/校验 embedding 模型，可能 2-3 分钟
curl -s localhost:8080/api/version
```

### 4. 未做的精简（有功能影响，需先改配置）

本地推理栈（torch / transformers / sentence-transformers / faster-whisper，约 1.5–2 GB）
**故意保留**：默认 `RAG_EMBEDDING_ENGINE=''`、`AUDIO_STT_ENGINE=''` 就是走本地，
删掉后上传文档 / 语音转写会直接报错。若要精简，需先确认 embedding / rerank / STT
全部走远程（Ollama 或 OpenAI 兼容 API），再加 `--build-arg USE_SLIM=true` 并移除
Dockerfile 里的 torch 安装行。

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

### v0.11.3 又移除 8 个（AST 扫 259 个 .py + pip 全图重解析双重验证）

| 依赖 | 依据 |
|---|---|
| `pytube` | YouTube 转写走 youtube-transcript-api，pytube 零引用 |
| `pypandoc` | 零引用（pandoc 二进制由 unstructured 使用，apt 包保留） |
| `pymdown-extensions` | `utils/pdf_generator.py` 里只剩注释掉的引用 |
| `opencv-python-headless` | rapidocr 移除后的遗留，零引用 |
| `pymongo` | 已无 MongoDB 向量库后端（`retrieval/vector/dbs/` 里没有） |
| `google-api-python-client` / `google-auth-oauthlib` / `google-auth-httplib2` | Drive 集成只剩前端 Picker，后端只传 client_id/api_key，Python SDK 零引用 |

**看着没用但必须留的**（靠字符串 / 动态加载，删了运行时报错）：

| 依赖 | 谁在用 |
|---|---|
| `rank-bm25` | langchain `BM25Retriever`（混合检索） |
| `openpyxl` / `xlrd` / `pyxlsb` | pandas `pd.ExcelFile` 的 Excel 引擎（ExcelLoader 回退路径） |
| `aiosqlite` | SQLAlchemy 默认 SQLite 方言名（删了**整个程序起不来**） |
| `pypdf` / `docx2txt` / `unstructured` / `nltk` / `python-docx` / `msoffcrypto-tool` | langchain loader 与 unstructured 的 docx/pdf/xlsx 解析路径 |
| `fpdf2` | `utils/pdf_generator.py` 的 `from fpdf import FPDF`（注意：模块名是 `fpdf` 不是 `fpdf2`） |
| `psycopg2-binary` | `retrieval/vector/dbs/opengauss.py` 的 `PGDialect_psycopg2` |
| `onnxruntime` | chromadb 硬依赖 |
| `openai` / `anthropic` / `langchain` | 用户自建 Functions / Tools 会 import |
| `aiodns` | 上游刻意 pin 的 aiohttp DNS-on-event-loop 方案 |
| `PyMySQL` | 可选 MySQL/MariaDB 主库驱动（`DATABASE_URL=mysql+pymysql://`） |

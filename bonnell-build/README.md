# Bonnell (x86-64-v1) 镜像构建指南

## 背景

Intel Atom D525（Bonnell 微架构）只支持到 SSSE3，不支持 SSE4.x/AVX。
Open WebUI 的 manylinux 预编译包默认要求 x86-64-v2（SSE4.2），在 Bonnell 上会 SIGILL 崩溃。

## 整体策略

- **镜像形态**：当前用 **slim**（`USE_SLIM=true`）——本地 AI 栈与本地文档解析整条链路
  全部交给远程服务，镜像里只剩 `numpy` 一个需要 Bonnell 重编的包。
  完整镜像的四个重编包仍列在下面，保留做法备查。
- **4 个包源码重建**：numpy、pyarrow、tokenizers、onnxruntime — 这些无法用运行时环境变量完全控制 SIMD
  （slim 下只有 numpy 会进镜像；pyarrow / tokenizers / onnxruntime 都不装）
- **其余包用 manylinux wheel**：scipy、sklearn、opencv、ctranslate2 等通过运行时环境变量控制 SIMD dispatch
- **Arrow C++ .so 直接拷贝**：pyarrow 依赖的 libarrow 库从 builder 镜像复制到最终镜像
  （仅完整镜像；slim 不装 pyarrow，也不再拷 `arrow-libs/`）
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

**当前部署形态：slim**（v0.11.4 起切换，详见下文「v0.11.4 升级记录」）：

```bash
# 实际使用：slim（外部 AI 服务 + pgvector）
docker build --network=host \
  -t open-webui:bonnell -t open-webui:bonnell-slim \
  --build-arg USE_SLIM=true --build-arg USE_CUDA=false --build-arg USE_OLLAMA=false \
  -f Dockerfile .
```

完整镜像（带本地 torch / chroma / 文档解析，已不再使用，仅保留命令备查）：

```bash
docker build --network=host -t open-webui:bonnell-full \
  --build-arg USE_CUDA=false --build-arg USE_OLLAMA=false \
  -f Dockerfile .
```

> 注意：主 Dockerfile 的 Bonnell 段使用 glob 匹配 wheel 文件名
> (`numpy-*.whl`, `pyarrow-*.whl` 等)，所以版本号变化不需要改 Dockerfile。
> slim 下只装 `numpy-*.whl`，不再复制 `arrow-libs/`。

### 8. 验证

完整镜像的导入检查（slim 下 torch / pyarrow / tokenizers / onnxruntime / opencv
都不在，请按下面 slim 版做）：

```bash
# 导入检查（完整镜像）
docker run --rm --entrypoint python3 open-webui:bonnell -c "
import numpy,pyarrow,tokenizers,onnxruntime,scipy,sklearn,cv2,sentencepiece,pandas,faster_whisper
print('All imports OK')
"
```

**slim 镜像的验证**（当前形态）：

```bash
# 1) 包清单：应该找不到 torch/pyarrow/tokenizers/onnxruntime/opencv/chromadb/playwright
#    而 numpy 必须是自编的那一份
docker run --rm --entrypoint bash open-webui:bonnell -c '
  python3 -c "import numpy; print(numpy.__version__, numpy.__file__)"
  pip3 list 2>/dev/null | grep -iE "torch|pyarrow|tokenizers|onnxruntime|opencv|chromadb|playwright|rapidocr" || echo "none of the heavy stack present (expected)"
  ldd /usr/local/lib/python3.11/site-packages/numpy/_core/_multiarray_umath*.so | grep openblas'

# 2) 真算一遍（走 OpenBLAS；若含本机不支持的指令会直接 rc=132 / SIGILL）
docker run --rm --entrypoint python3 open-webui:bonnell -c "
import numpy as np
print(float((np.random.rand(512,512).astype('float32') @ np.random.rand(512,512).astype('float32')).sum()))"

# 3) 起容器（未配外部 embedding/pgvector 时 /health 能过，但 RAG 功能会 503）
docker run -d --name test -p 8080:8080 open-webui:bonnell
docker inspect -f '{{.State.Health.Status}}' test   # 等 2-3 分钟
curl -s localhost:8080/api/version; curl -s localhost:8080/api/config | head -c 300
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

### 4. 未做的精简（已在 v0.11.4 改为 slim）

v0.11.3 当时**故意保留**了本地推理栈（torch / transformers / sentence-transformers /
faster-whisper，约 1.5–2 GB），因为默认 `RAG_EMBEDDING_ENGINE=''`、
`AUDIO_STT_ENGINE=''` 就是走本地，删掉后上传文档 / 语音转写会直接报错。

v0.11.4 已改为 **slim 形态**（`--build-arg USE_SLIM=true`），代价是上面第 2 节列的那些
远程替代必须真的配好；否则相关功能会直接 503（不是静默降级）。

## v0.11.4 升级记录（2026-10-01）

合并上游 v0.11.4（自 v0.11.3 起 327 个提交）。冲突只有两处：`backend/requirements.txt`
和 `backend/requirements-min.txt`（后者上游已删）。

### 1. 依赖变化

| 项 | 变化 | 说明 |
|---|---|---|
| numpy / pyarrow / onnxruntime / tokenizers | **无变化** | `uv.lock` 仍是 numpy 2.4.6 / pyarrow 20.0.0 / tokenizers 0.22.2 / onnxruntime 1.26.0，`bonnell-wheels/` 里的 wheel 直接复用，无需重编 |
| `rapidocr==3.9.2` + `opencv-python-headless==4.13.0.92` | **必须加回** | 上游新增 `retrieval/loaders/pdf.py`，里面有 `from rapidocr import RapidOCR` 做 PDF 内嵌图片 OCR（`PDF_EXTRACT_IMAGES` 打开时走这条路径）。本 fork 在 v0.10 以「零引用」删掉的这两个包现在真的有引用了 |
| `google-re2` | 新增 | `tools/knowledge_fs.py` 里 `import re2`（知识库正则，bounding/线性时间），native 扩展，无 SIMD 风险 |
| `langchain` / `langchain-community` | 移除 | 上游改用 `langchain-core` + `langchain-classic` |
| `google-genai` / `async-timeout` | 移除 | 上游不再使用 |
| `fpdf2` / `nltk` / `pymdown-extensions` / `pytube` / `pymongo` / `google-api-python-client` / `google-auth-*` | 移除 | **上游自己删掉了**（`utils/pdf_generator.py` 整个文件也删了），本 fork 不用再单独维护这份清单 |
| `pypandoc` | 继续不装 | 上游 requirements.txt 里仍有，但代码零引用；这是本 fork 现在**唯一**的 requirements 差异 |

> 结论：原生二进制里只多了 **opencv-python-headless** 一个 SIMD 相关包。它带 CPUID
> 运行时分发，Dockerfile 里也有 `OPENCV_CPU_DISABLE` 兜底；rapidocr 本身纯 Python，
> 推理走 onnxruntime（运行时分发）。其余与 v0.11.3 镜像一致。

> 注：本次实际部署的是 **slim** 变体（见下面第 2 节）——opencv / rapidocr / pyarrow /
> tokenizers 都不会进镜像，所以上面那些原生二进制的风险不落到最终镜像上。

### 2. 改用 slim 镜像（本次的主要决定）

上游 v0.11.4 新增了 `USE_SLIM` 变体 + `backend/requirements-slim.txt`（不含 torch /
pyarrow / tokenizers / chromadb / playwright / unstructured / 云存储 SDK 等）。本 fork
已改用这个形态，镜像里只剩 **numpy 一个需要 Bonnell 重编的包**（`numpy-2.4.6` 正好等于
slim 里 pin 的版本），pyarrow / tokenizers / onnxruntime / opencv / torch / scipy /
sklearn / ctranslate2 全部不进镜像，objdump 审计面基本清零。

**Dockerfile 随之改动的两个地方：**

```dockerfile
# Bonnell 段：slim 下只装 numpy wheel，跳过 pyarrow/tokenizers + arrow-libs
RUN set -e; \
    if [ "$USE_SLIM" = "true" ]; then \
    pip3 install --no-cache-dir --force-reinstall --no-deps /tmp/bonnell-wheels/numpy-*.whl; \
    else ...三个 wheel + cp arrow-libs...; fi

# 运行时库：libthrift/libutf8proc 是 libarrow 专用，slim 下不装
RUN apt-get update && \
    apt-get install -y --no-install-recommends libopenblas0 libre2-9 && \
    if [ "$USE_SLIM" != "true" ]; then apt-get install -y --no-install-recommends libthrift-0.17.0 libutf8proc2; fi && ...
```

`libopenblas0` **必须留**：我们的 numpy wheel 是动态链接系统 `libopenblas.so.0` 的
（`ldd numpy/_core/_multiarray_umath*.so` 可验证），`OPENBLAS_CORETYPE=BONNELL` 也就是
作用于它。其余两个 ENV（`ARROW_USER_SIMD_LEVEL` / `OPENCV_CPU_DISABLE`）在 slim 里
是空转，留着只为了完整镜像。

#### slim 少了什么、用什么顶（部署前必须逐条落实）

| 功能 | 远程替代 | 配置项 |
|---|---|---|
| 本地 embedding | ✅ openai / ollama / azure_openai | `RAG_EMBEDDING_ENGINE`（**默认空串=本地，必须显式改**） |
| 本地 rerank（colbert） | ⚠️ 只能 external | `RAG_RERANKING_ENGINE=external` + `RAG_EXTERNAL_RERANKER_URL/API_KEY`；或清空 reranking model 退回 cosine |
| 本地 Whisper STT | ✅ openai / deepgram / azure / mistral | `AUDIO_STT_ENGINE`。slim 强制 `BYPASS_PYDUB_PREPROCESSING=true`：**原始音频直接上传**，webm/opus 只有接受它的供应商才行；Mistral 那条路径硬限 mp3/wav |
| 本地 TTS | ✅ openai / elevenlabs / azure / mistral | `AUDIO_TTS_ENGINE`（本地 `transformers` 引擎 503） |
| 文档解析（PDF/DOCX/PPTX/XLSX/OCR） | ✅ tika / docling / document_intelligence / mistral_ocr / paddleocr_vl / datalab_marker / mineru / external | `CONTENT_EXTRACTION_ENGINE` + 对应 URL/key。本地只剩 txt/md/rst/xml/html/csv |
| 网页抓取 | ✅ safe_web（默认，纯 HTTP）/ firecrawl / tavily / microsoft_web_iq / external | `WEB_LOADER_ENGINE`（只有 playwright 被砍） |
| DuckDuckGo 搜索 | ✅ 换一家（其余 ~25 家都是 HTTP 实现） | searxng / brave / kagi / tavily / exa / serper / google_pse / perplexity / jina / mojeek / linkup / yandex / bing / searchapi / openserp / staan / bocha … |
| 评估页语义聚类 | ✅ 用已配好的外部 embedding | 无额外配置 |

**没有远程 API 等价物的 4 个硬缺口：**

1. **云存储**：`STORAGE_PROVIDER` 只能 `local`（boto3 / GCS / Azure Blob 全砍），只能靠挂盘；
2. **向量库只能 pgvector**：`factory.py` 里 `USE_SLIM and vector_type != PGVECTOR → 503`，远程 Chroma / Qdrant / Milvus 也一律拒，必须自备 Postgres+pgvector（`VECTOR_DB=pgvector` + `PGVECTOR_DB_URL`）；
3. **RAG 分词器降级**：`RAG_TOKENIZER_MODEL`（transformers）在 slim 下 503，只能用 character/token 切分；
4. **本地 rerank 无等价服务**，除非自己架一个外部 reranker HTTP 服务。

还有两条约束：`USE_SLIM=true` 与 `USE_OLLAMA/USE_CUDA` 上游硬校验互斥（Ollama 得是独立容器）；
主库只能是 SQLite / PostgreSQL。

#### 本次构建实测（2026-10-01）

| 项 | 结果 |
|---|---|
| 镜像体积 | **1.03 GB**（`open-webui:bonnell` 与 `open-webui:bonnell-slim` 指向同一 digest；完整镜像未建完，无对比数据） |
| 前端构建 | `npm run build` 142 s 通过（`NODE_OPTIONS=--max-old-space-size=8192`） |
| 包清单 | site-packages 共 175 个包；torch / pyarrow / tokenizers / onnxruntime / opencv / chromadb / playwright / rapidocr / transformers / scipy / pandas **均不存在** |
| numpy | 2.4.6，自编 wheel，动态链接系统 `libopenblas.so.0`（`OPENBLAS_CORETYPE=BONNELL` 生效） |
| 静态扫描 | numpy 全部 .so = **0** 条 v2 指令；新增的 `re2` 只命中 52 条 `tzcnt`（BMI1 的 `F3 0F BC` 编码，在不支持 BMI1 的 CPU 上按 `BSF` 解码 —— Bonnell 安全） |
| 运行 | 容器 60 s 内 healthy；`/health` → `{"status":true}`；`/api/version` → `0.11.4`；`/api/config` → `features.slim: true` |
| 遗留 | 仍未在 Atom D525 实机复测；且部署前必须配好外部 embedding / rerank / STT / TTS / 文档提取 / pgvector，否则对应功能直接 503 |

### 3. 主 Dockerfile 的上游重构（已与 Bonnell 段干净合并）

- 新增 `USE_SLIM` 变体 + `backend/requirements-slim.txt`；
- pip 安装段改成 `RUN --mount=from=ghcr.io/astral-sh/uv:0.12.10,source=/uv,target=/bin/uv`，**需要 BuildKit**（现代 docker 默认开启）；
- 构建阶段把 `chown/chgrp/chmod` 提前，后端改为 `COPY --from=build /app/backend .`；
- 上游基础镜像仍写未定版的 `python:3.11-slim-bookworm`，本 fork 保持 pin 到 `3.11.14`，与 4 个 bonnell builder 的 `BASE_IMAGE` 对齐。

### 4. v1 兼容性：待实机复测

v0.11.4 升级当天只做了合并 + 静态审计（AST 扫依赖、`compileall`、requirements 与
上游逐行对齐），**尚未在 Atom D525 上跑过**。slim 下要复查的东西比完整镜像少得多：

1. 静态 `objdump` 扫描 —— 预期只剩 numpy（自编，应为 0 条 v2 指令）与少量纯 Python/wheel 自带的 .so；
2. 逐模块独立进程 `import numpy` + 真算一遍矩阵乘（numpy 之外的 torch/pyarrow 已不在镜像里）；
3. 起容器验 `/health` 与 `/api/version`，并逐项确认上面的远程替代已配好（否则会直接 503）。

## 版本升级注意事项

| 组件 | 需检查 | 说明 |
|---|---|---|
| Python 版本 | 所有 `Dockerfile.build-*` 的 `BASE_IMAGE` arg 必须与主 Dockerfile base 一致 | 当前 `python:3.11.14-slim-bookworm` |
| Arrow C++ | `Dockerfile.build-pyarrow` 的 `ARROW_VERSION` build arg | 必须与 requirements.txt 中 pyarrow 版本一致 |
| onnxruntime | `Dockerfile.build-onnxruntime` 的 `ORT_VERSION` build arg | 必须与 requirements.txt 中 onnxruntime 版本一致 |
| numpy / tokenizers | 不锁定版本，自动构建兼容版 | 主 Dockerfile 用 glob 匹配，无需修改；但先用 `grep -A2 '^name = "numpy"' uv.lock` 确认上游解析到的版本，看 `bonnell-wheels/` 里的 wheel 是否对得上。**slim 下唯一会进镜像的就是 numpy**，所以这个对齐最要紧 |
| wheel 与 `uv pip install` 的版本一致 | pyarrow / onnxruntime 在 requirements.txt 里 pin，numpy / tokenizers 由解析决定 | Bonnell 段用 `--force-reinstall --no-deps` 覆盖，只换二进制不改依赖图；slim 只覆盖 numpy。版本差异过大可能 ABI 不匹配 |
| slim 的依赖清单 | `backend/requirements-slim.txt` 由上游维护，与本 fork 的 `requirements.txt` 差异无关 | 升级时比对 `comm -23 <(sort requirements.txt) <(sort requirements-slim.txt)` 看新增/移除了什么 |
| wheel 文件名中的 `cp311` | Python 大版本变了要更新 | 如 Python 3.12 → `cp312` |
| 运行时库包名 | `libre2-9`、`libthrift-0.17.0` | Debian bookworm 的 `apt-cache search` 检查 |
| pyarrow `__version__ = None` 修复 | 自动从 wheel 文件名提取版本并 sed | 如果 Arrow 修了 shallow clone 版本问题可去除此段 |

## 运行时 SIMD 控制总结

当前镜像为 slim：下表里 **ARROW / OPENCV 两行是空转**（对应包不在镜像里），
`NPY_DISABLE_CPU_FEATURES` 与 `OPENBLAS_CORETYPE` 依然生效且关键。

| 环境变量 | 控制范围 | Bonnell 设置 |
|---|---|---|
| `OPENBLAS_CORETYPE` | OpenBLAS（numpy 的 BLAS；slim 下唯一相关项） | `BONNELL` |
| `ARROW_USER_SIMD_LEVEL` | Arrow C++ CPU dispatch（**slim 下无此包**） | `NONE` |
| `OPENCV_CPU_DISABLE` | OpenCV 多架构 dispatch（**slim 下无此包**） | `AVX2,AVX,SSE4.2,SSE4.1,SSSE3,SSE3` |
| `NPY_DISABLE_CPU_FEATURES` | numpy CPU feature 检测 | `AVX,AVX2,AVX512F,FMA3,FMA4,SSE4_1,SSE4_2,POPCNT` |
| Rust `is_x86_feature_detected!` | tokenizers / chromadb / hf_xet 等（**slim 下均不在**） | 运行时自动检测，Bonnell 回退 scalar |

## 依赖增删记录（累计，已按 v0.11.4 复核）

### v0.11.0：移除 3 个

| 依赖 | 现状 |
|---|---|
| `APScheduler` | v0.11.4 上游也已移除 |
| `RestrictedPython` | v0.11.4 上游也已移除 |
| `rapidocr-onnxruntime` | 旧包名；上游现在改用 `rapidocr==3.9.2`，且**真的有引用**（PDF OCR），已加回 |

### v0.11.3：又移除 8 个（AST 扫 259 个 .py + pip 全图重解析双重验证）

| 依赖 | 现状 |
|---|---|
| `pytube` / `pymdown-extensions` / `pymongo` / `google-api-python-client` / `google-auth-oauthlib` / `google-auth-httplib2` | v0.11.4 上游自己删了，不用再单独维护 |
| `opencv-python-headless` | **v0.11.4 加回**：rapidocr 的依赖，`retrieval/loaders/pdf.py` 用 |
| `pypandoc` | 上游一直保留，本 fork 继续不装（代码零引用）；目前是唯一的 requirements.txt 差异 |

> 教训：删「零引用依赖」前要确认该依赖不是被新上游代码**即将**引用的。
> `opencv-python-headless` 就是这么被删了又加回来的（上次还连带删了 rapidocr）。

**看着没用但必须留的**（靠字符串 / 动态加载，删了运行时报错）：

| 依赖 | 谁在用 |
|---|---|
| `rapidocr` + `opencv-python-headless` | `retrieval/loaders/pdf.py` 的 PDF 图片 OCR（`PDF_EXTRACT_IMAGES`） |
| `google-re2` | `tools/knowledge_fs.py` 的 `import re2`（v0.11.4 新增） |
| `rank-bm25` | langchain `BM25Retriever`（混合检索） |
| `openpyxl` / `xlrd` / `pyxlsb` | pandas `pd.ExcelFile` 的 Excel 引擎（ExcelLoader 回退路径） |
| `aiosqlite` | SQLAlchemy 默认 SQLite 方言名（删了**整个程序起不来**） |
| `pypdf` / `docx2txt` / `unstructured` / `python-docx` / `msoffcrypto-tool` | langchain loader 与 unstructured 的 docx/pdf/xlsx 解析路径 |
| `psycopg2-binary` | `retrieval/vector/dbs/opengauss.py` 的 `PGDialect_psycopg2` |
| `onnxruntime` | chromadb 硬依赖，也是 rapidocr 的推理后端 |
| `openai` / `anthropic` / `langchain-core` | 用户自建 Functions / Tools 会 import |
| `aiodns` | 上游刻意 pin 的 aiohttp DNS-on-event-loop 方案 |
| `PyMySQL` | 可选 MySQL/MariaDB 主库驱动（`DATABASE_URL=mysql+pymysql://`） |

**已在 v0.11.4 从清单里划掉的**（上游把对应代码一起删了，不再需要保留）：
`fpdf2`（`utils/pdf_generator.py` 已删）、`nltk`（上游去掉了 nltk 分词/下载）、
`pymdown-extensions`、`pytube`、`pymongo`、`google-api-python-client` 系列。


#!/bin/bash
# 扫描镜像内所有 .so，统计 x86-64-v2+ 指令（Bonnell 不支持的）
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq binutils >/dev/null 2>&1
command -v objdump >/dev/null || { echo "objdump 装不上"; exit 1; }

SP=$(python3 -c 'import site;print(site.getsitepackages()[0])')
echo "site-packages: $SP"

scan_one() {
  f="$1"
  tmp="/tmp/d.$BASHPID.txt"
  objdump -d "$f" 2>/dev/null > "$tmp" || { rm -f "$tmp"; return; }
  vex=$(grep -cE '\bv[a-z][a-z0-9]*[[:space:]]' "$tmp")
  sse=$(grep -cE '\b(popcnt|ptest|pcmpistri|pcmpestri|crc32|pcmpgtq|pmulld|pminud|pmaxud|pmovsx[a-z]*|pmovzx[a-z]*|roundps|roundpd|roundss|roundsd|blendps|blendpd|pblendw|pinsrb|pinsrd|pinsrq|pextrb|pextrd|pextrq|packusdw|phminposuw|dpps|dppd|mpsadbw|insertps|extractps|movntdqa|extrq|insertq)\b' "$tmp")
  bmi=$(grep -cE '\b(andn|bextr|blsi|blsmsk|blsr|tzcnt|lzcnt|bzhi|mulx|pdep|pext|rorx|sarx|shlx|shrx|movbe|rdrand|rdseed|aesenc|aesdec|aesenclast|aesdeclast|aeskeygenassist|pclmulqdq|sha1rnds4|sha256rnds2)\b' "$tmp")
  cid=$(grep -cE '\bcpuid\b' "$tmp")
  rm -f "$tmp"
  name="${f#$SP/}"
  pkg=$(echo "$name" | cut -d/ -f1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pkg" "$vex" "$sse" "$bmi" "$cid" "$name"
}
export -f scan_one; export SP

find "$SP" -type f \( -name '*.so' -o -name '*.so.*' \) -size +16k 2>/dev/null | sort \
  | xargs -P 12 -I{} bash -c 'scan_one "$@"' _ {} > /tmp/scan_raw.tsv 2>/dev/null

echo
echo "=== 按包汇总 (Bonnell 不支持的 v2+ 指令) ==="
printf '%-32s %9s %9s %10s %7s\n' "package" "VEX/AVX" "SSE4.x" "BMI/其他" "cpuid"
awk -F'\t' '{v[$1]+=$2; s[$1]+=$3; b[$1]+=$4; c[$1]+=($5>0?1:0)} END {
  for (p in v) if (v[p]+s[p]+b[p] > 0)
    printf "%-32s %9d %9d %10d %7s\n", p, v[p], s[p], b[p], (c[p]>0?"有":"无");
}' /tmp/scan_raw.tsv | sort -k2 -nr

echo
echo "=== 我们自己重编译的 Bonnell wheel（必须 0）==="
for lib in numpy pyarrow tokenizers; do
  awk -F'\t' -v L="$lib" '$1==L {v+=$2;s+=$3;b+=$4} END {printf "  %-12s VEX=%d SSE4.x=%d BMI=%d\n", L, v+0, s+0, b+0}' /tmp/scan_raw.tsv
done

echo
echo "=== 含 v2+ 指令的文件里，没有任何 CPUID 分发的（最高风险）==="
awk -F'\t' '$5==0 && ($2+$3+$4)>0 {printf "  %-62s VEX=%s SSE4=%s BMI=%s\n", $6, $2, $3, $4}' /tmp/scan_raw.tsv | head -25
awk -F'\t' '$5==0 && ($2+$3+$4)>0' /tmp/scan_raw.tsv | wc -l | xargs printf "  小计: %s 个文件\n"

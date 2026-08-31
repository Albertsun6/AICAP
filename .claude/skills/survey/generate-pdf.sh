#!/usr/bin/env bash
# generate-pdf.sh — PDF generator for /survey reports
#
# 原理:用 Chrome headless 打印**已生成的交互式 HTML**(finalize 步骤 4.5 产物)。
# 为什么不用 pandoc/LaTeX:中文字体链配置脆弱,且 HTML 已有 print CSS(隐藏目录/按钮、
# 分页避免截断),Chrome 打印保真度最高、零额外依赖。
#
# 注意:HTML 依赖 CDN(Tailwind/Mermaid),Chrome 需联网;--virtual-time-budget 给
# CDN 加载与 Mermaid 异步渲染留时间。离线环境会得到无样式但内容完整的 PDF。
#
# Usage: generate-pdf.sh [-o OUT] HTML
#   -o OUT   custom output path (default: <HTML%.html>.pdf)
# Exit codes:
#   0  — success
#   2  — usage / html not found / invalid path
#   65 — 无可用 Chrome/Chromium(caller 记 metadata skipped,不阻断)
#   66 — Chrome 存在但打印失败或产物为空

set -euo pipefail

OUT_ARG=""
while getopts ":o:" opt; do
  case "$opt" in
    o) OUT_ARG="$OPTARG" ;;
    \?) echo "Usage: $0 [-o OUT] HTML" >&2; exit 2 ;;
    :) echo "Option -$OPTARG requires an argument" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

HTML="${1:-}"
if [[ -z "$HTML" || ! -f "$HTML" ]]; then
  echo "Usage: $0 [-o OUT] HTML" >&2
  exit 2
fi
if [[ "$HTML" == *$'\n'* || "$OUT_ARG" == *$'\n'* ]]; then
  echo "ERROR: path contains newline" >&2
  exit 2
fi

OUT="${OUT_ARG:-${HTML%.html}.pdf}"

# 找 Chrome/Chromium:macOS app bundle 优先,再试 PATH(Linux/别名安装)
CHROME=""
for c in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
  [[ -x "$c" ]] && CHROME="$c" && break
done
if [[ -z "$CHROME" ]]; then
  for c in google-chrome google-chrome-stable chromium chromium-browser; do
    command -v "$c" >/dev/null 2>&1 && CHROME="$(command -v "$c")" && break
  done
fi
if [[ -z "$CHROME" ]]; then
  echo "PDF generation: skipped (no Chrome/Chromium found)" >&2
  exit 65
fi

# 绝对路径(file:// 需要)
case "$HTML" in
  /*) HTML_ABS="$HTML" ;;
  *) HTML_ABS="$(cd "$(dirname "$HTML")" && pwd)/$(basename "$HTML")" ;;
esac

# --virtual-time-budget=20000:给 CDN + Mermaid 渲染最多 20s 虚拟时间
# --no-pdf-header-footer:去掉 Chrome 默认页眉页脚(日期/URL)
if ! "$CHROME" --headless --disable-gpu --no-sandbox \
    --no-pdf-header-footer \
    --virtual-time-budget=20000 \
    --print-to-pdf="$OUT" \
    "file://$HTML_ABS" >/dev/null 2>&1; then
  echo "PDF generation: failed (chrome returned non-zero)" >&2
  exit 66
fi

if [[ ! -s "$OUT" ]]; then
  echo "PDF generation: failed (empty output)" >&2
  exit 66
fi

SIZE=$(du -h "$OUT" | cut -f1)
echo "PDF report: $OUT ($SIZE, engine: $(basename "$CHROME"))"
exit 0

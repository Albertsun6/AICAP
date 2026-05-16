#!/usr/bin/env bash
# check-citations.sh — Layer A URL Health Check for /survey skill Phase 5.5
#
# Usage: check-citations.sh <report.md>
# Output:
#   <report.md>.citation-health.json — full per-URL result
#   stdout — short summary
# Exit codes:
#   0  — PASS（dead URL ≤ 10%）
#   65 — FAIL Layer A（dead URL > 10%）
#   2  — usage / missing dependency error
#
# Layer B（claim-support verification）由主 agent 后续做，本脚本不处理。

set -euo pipefail

REPORT="${1:-}"
if [[ -z "$REPORT" || ! -f "$REPORT" ]]; then
  echo "Usage: $0 <report.md>" >&2
  exit 2
fi

for cmd in curl jq grep; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found" >&2
    exit 2
  fi
done

OUT="${REPORT}.citation-health.json"
TIMEOUT=10
DEAD_THRESHOLD=10  # 百分比，超过则 FAIL

# Step 1: 抽 URL（markdown 链接 + 裸 URL），dedup
# Portable bash 3.2+ array fill (macOS 默认 bash 没有 mapfile)
URLS=()
while IFS= read -r url; do
  [[ -n "$url" ]] && URLS+=("$url")
done < <(grep -oE 'https?://[^ )"<>]+' "$REPORT" | sed 's/[.,;:]*$//' | sort -u)

TOTAL="${#URLS[@]}"
if (( TOTAL == 0 )); then
  printf '{"total":0,"ok":0,"wayback":0,"dead":0,"results":[],"verdict":"PASS","reason":"no URLs found"}\n' > "$OUT"
  echo "PASS: no URLs in $REPORT"
  exit 0
fi

OK=0
WAYBACK=0
DEAD=0
declare -a RESULTS=()

BLOCKED=0  # 4xx/5xx 但 server 在线（bot 拦 / 临时错误），不算 dead

for URL in "${URLS[@]}"; do
  # curl -I (HEAD)，跟随重定向，10s timeout
  STATUS=$(curl -I -o /dev/null -s -w "%{http_code}" --max-time "$TIMEOUT" -L "$URL" 2>/dev/null || echo "000")

  # HEAD 被 bot-block (403/405/501) → GET 重试一次（仅取首字节）
  if [[ "$STATUS" =~ ^(403|405|501)$ ]]; then
    STATUS=$(curl -o /dev/null -s -w "%{http_code}" --max-time "$TIMEOUT" -L --range 0-0 "$URL" 2>/dev/null || echo "000")
  fi

  # 分类：
  # 2xx        → ok
  # 401/403    → blocked（server 在线但拦 bot；不算 dead）
  # 404/410    → dead（resource 真不存在）
  # 5xx        → blocked（server 临时错误；不算 dead）
  # 000        → 真断连 → 查 Wayback；找到则 wayback，否则 dead
  # 其他       → wayback 兜底
  if [[ "$STATUS" =~ ^(200|201|202|203|204|205|206|300|301|302|303|307|308)$ ]]; then
    OK=$((OK+1))
    RESULTS+=("$(jq -n --arg url "$URL" --arg status "$STATUS" \
      '{url:$url,status:$status,state:"ok"}')")
  elif [[ "$STATUS" =~ ^(401|403)$ ]]; then
    BLOCKED=$((BLOCKED+1))
    RESULTS+=("$(jq -n --arg url "$URL" --arg status "$STATUS" \
      '{url:$url,status:$status,state:"blocked",note:"server alive but refuses bot access"}')")
  elif [[ "$STATUS" =~ ^(404|410)$ ]]; then
    DEAD=$((DEAD+1))
    RESULTS+=("$(jq -n --arg url "$URL" --arg status "$STATUS" \
      '{url:$url,status:$status,state:"dead",note:"resource not found"}')")
  elif [[ "$STATUS" =~ ^5 ]]; then
    BLOCKED=$((BLOCKED+1))
    RESULTS+=("$(jq -n --arg url "$URL" --arg status "$STATUS" \
      '{url:$url,status:$status,state:"blocked",note:"server error 5xx"}')")
  else
    # 真断连或其他不明状态 → 查 Wayback
    WAY_URL=$(curl -s --max-time "$TIMEOUT" \
      "https://archive.org/wayback/available?url=$URL" 2>/dev/null \
      | jq -r '.archived_snapshots.closest.url // empty' 2>/dev/null || true)
    if [[ -n "$WAY_URL" ]]; then
      WAYBACK=$((WAYBACK+1))
      RESULTS+=("$(jq -n --arg url "$URL" --arg status "$STATUS" --arg way "$WAY_URL" \
        '{url:$url,status:$status,state:"wayback",wayback_url:$way}')")
    else
      DEAD=$((DEAD+1))
      RESULTS+=("$(jq -n --arg url "$URL" --arg status "$STATUS" \
        '{url:$url,status:$status,state:"dead",note:"no response, no wayback snapshot"}')")
    fi
  fi
done

# 汇总 JSON
DEAD_PCT=$(( DEAD * 100 / TOTAL ))
VERDICT="PASS"
REASON=""
if (( DEAD_PCT > DEAD_THRESHOLD )); then
  VERDICT="FAIL_LAYER_A"
  REASON="dead URL ratio ${DEAD_PCT}% > threshold ${DEAD_THRESHOLD}%"
fi

# 写 results 到一个临时 jq stream
RESULTS_JSON=$(printf '%s\n' "${RESULTS[@]}" | jq -s '.')

jq -n \
  --argjson total "$TOTAL" \
  --argjson ok "$OK" \
  --argjson wayback "$WAYBACK" \
  --argjson blocked "$BLOCKED" \
  --argjson dead "$DEAD" \
  --argjson dead_pct "$DEAD_PCT" \
  --arg verdict "$VERDICT" \
  --arg reason "$REASON" \
  --argjson results "$RESULTS_JSON" \
  '{total:$total, ok:$ok, wayback:$wayback, blocked:$blocked, dead:$dead, dead_pct:$dead_pct, verdict:$verdict, reason:$reason, results:$results}' \
  > "$OUT"

# stdout 简报
echo "Layer A Citation Health Check：$REPORT"
echo "  Total URLs: $TOTAL"
echo "  ok:        $OK"
echo "  wayback:   $WAYBACK"
echo "  blocked:   ${BLOCKED} (bot-blocked / 5xx, not counted as failure)"
echo "  dead:      $DEAD ($DEAD_PCT%)"
echo "  Verdict:   $VERDICT"
[[ -n "$REASON" ]] && echo "  Reason:    $REASON"
echo "  Full JSON: $OUT"

if [[ "$VERDICT" == "FAIL_LAYER_A" ]]; then
  exit 65
fi
exit 0

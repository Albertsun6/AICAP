只改 .rulesync/ 源,绝不手改生成产物(会被下次 generate 覆盖)。生成产物纳入版本控制,以便 CI drift gate(ai:check = generate && git diff --exit-code)比对。.rulesync/rules/ 为人工触发,AI 只读。

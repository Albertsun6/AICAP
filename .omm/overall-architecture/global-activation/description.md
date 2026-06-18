scripts/setup-global-skills.sh(经 pnpm run setup:skills)把每个 .claude/skills/<name> symlink 进 ~/.claude/skills/,使 Claude Code / Cursor / Codex 在任意项目都能发现这些 skill。幂等、不覆盖已存在的真实目录。

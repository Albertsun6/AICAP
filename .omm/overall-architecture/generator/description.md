rulesync 8.18.0(devDependency),经 pnpm run ai:generate (= rulesync generate) 调用。读 .rulesync/,把同一份能力翻译成每个工具的原生目录/文件名。ai:check = generate + git diff --exit-code,作为 CI drift gate。

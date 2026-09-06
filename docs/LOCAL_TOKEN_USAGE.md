# 本地 Token 统计 / Local token usage

## 参考项目 / References

2026-09-06 通过 GitHub 公共 API 查询热度并阅读源码。Star 是当日快照，会变化。CodexTip 独立使用 Swift / AppKit 实现，没有引入或复制第三方统计库源码。

Popularity was checked through GitHub’s public API on 2026-09-06. Stars are a changing snapshot. CodexTip uses its own Swift / AppKit implementation; no third-party tracking library code is bundled or copied.

| 项目 / Project | Stars（当日 / snapshot） | 参考点 / Approach |
| --- | ---: | --- |
| [CodexBar](https://github.com/steipete/CodexBar) | 20,984 | 本地日志索引、增量读取、输入/输出/缓存拆分 / Local indexes, incremental reads, input/output/cache breakdown |
| [ccusage](https://github.com/ccusage/ccusage) | 18,382 | Codex token_count、累计快照去重、fork 继承历史处理 / Token records, cumulative deduplication, inherited fork history |

固定研究版本 / Pinned source references:

- [CodexBar indexer, 559bfc8](https://github.com/steipete/CodexBar/blob/559bfc818eb7b757d4763642a86586c40098d08a/Sources/CodexBarCore/CodexLocalProjectUsageIndexer.swift)
- [CodexBar local parser](https://github.com/steipete/CodexBar/blob/559bfc818eb7b757d4763642a86586c40098d08a/Sources/CodexBarCore/Vendored/OpenCodexUsage/OpenCodexUsageParser.swift)
- [ccusage parser, 07b6a29](https://github.com/ccusage/ccusage/blob/07b6a2946415552288369f6d724a7681c17ff8b7/rust/adapters/codex/src/parser.rs)
- [ccusage replay handling](https://github.com/ccusage/ccusage/blob/07b6a2946415552288369f6d724a7681c17ff8b7/rust/adapters/codex/src/replay.rs)
- [ccusage Codex guide](https://ccusage.com/guide/codex/)

## 数据范围 / Scope

- 默认扫描 `~/.codex/sessions` 和 `~/.codex/archived_sessions` 的 JSONL；尊重启动进程的 `CODEX_HOME`，仅接受一个根目录。无账号过滤，无网络请求，不读取 `auth.json`。
- 只索引用量和必要元数据：时间、模型、计数、累计基线、散列会话/父会话标识和文件续读位置。不会在索引中保存聊天正文、工具输出、原始会话 ID、目录名或账号。
- 通过 Finder 启动的 App 不一定继承终端中的环境变量；在终端设置 `CODEX_HOME` 只会影响从该环境新启动的进程。

Scans JSONL under `sessions` and `archived_sessions` in `~/.codex`, or a single `CODEX_HOME` root inherited by the process. No account filtering, network access, or authentication-file reads are involved. The index contains usage metadata and hashed session/file identifiers, not conversation text, tool output, raw IDs, paths, or accounts. Finder launches may not inherit shell environment variables.

## 计数与去重 / Counting and deduplication

1. 解析 `event_msg` 中的 `token_count.info`。优先采用 `last_token_usage`；缺失时使用 `total_token_usage` 相对前一累计值的非负差值。累计值未变化时跳过重复快照。
2. 总量始终为 `input_tokens + output_tokens`。`cached_input_tokens` 包含在输入内，`reasoning_output_tokens` 包含在输出内，不能再加到总量。缓存命中率为缓存输入 / 全部输入。
3. 模型来自事件元数据或最近的 `turn_context.model`；无法识别时显示「模型未知」，不猜测模型。
4. 同一会话 ID 的多个文件选择记录最完整的版本；跨会话按时间、模型和计数签名去除完全一致的重复事件。
5. 有 `subagent_history_start_ordinal` 时跳过边界之前的继承事件，但仍更新累计基线，防止下一条把历史重新算入。旧版 fork 则匹配父会话的计数/累计前缀，同时忽略早于子会话创建时间的继承事件。
6. 按本机自然日统计。7 天是今天及此前 6 天；今天之后的记录不计入当前数字。记录条数是用量事件数，不保证等于请求数或消息数。

The parser prefers per-event usage, falls back to nonnegative cumulative deltas, and skips unchanged cumulative snapshots. Total is input plus output; cache and reasoning are subsets. Models come from event metadata or the latest turn context, otherwise “Unknown model.” Duplicate session files and identical event signatures are deduplicated. Subagent history ordinals exclude inherited usage while preserving the cumulative baseline. Legacy forks match the parent’s usage prefix and exclude pre-creation records. Date buckets follow the local calendar, include today, and exclude future records. Usage-record counts are not request or message counts.

## 增量索引 / Incremental indexing

- 后台首次流式扫描全部日志，之后从上次完整换行处续读；末尾正在写入的半条 JSON 留到下一次刷新。单行缓冲上限 16 MiB，超长工具输出不会无限占用内存。
- 每次扫描检查文件大小、修改时间、inode 及开头最多 4 KiB 的指纹；截断、替换、同大小重写等常见变化会触发重建。文件全部枚举成功后，才移除已删除日志的索引。
- 续读仍会枚举目录、读取短指纹、聚合索引；诊断 `warmBytesRead` 只计正文续读字节，不包含指纹读取。
- 保存到 `~/Library/Application Support/CodexTip/local-token-index.json`，目录 `700`，文件 `600`。独立于 48 小时的账号额度历史，升级不清空；删掉索引会重建，删除源日志则下次移除相应用量。

The first scan streams all logs on a background worker. Later scans resume after the last complete newline; partial trailing JSON is retried. A 16 MiB line buffer bounds memory for large tool output. File size, modification time, inode, and a short prefix fingerprint invalidate common rewrites. Deleted files are dropped only after successful enumeration. Warm scans still enumerate, fingerprint, and aggregate; `warmBytesRead` reports body reads only. The private index persists independently of quota history and can be deleted safely to rebuild it.

## 已知限制 / Limits

- 本地保留的 token 日志不是账单，不能恢复缺失日志，也不自动汇总其他设备或未落盘的云端任务。
- 旧版 fork 若没有父日志、没有继承边界且时间被重写，无法可靠判断所有继承数据；界面会提示缺少父日志。更复杂或未来的日志结构也可能导致缺失/重复。
- 跨会话完全相同的时间/模型/计数签名可能极少数情况下属于独立请求；当前去重方式可能少计这些碰撞。未来日志若提供稳定事件 ID，可进一步改进。
- 指纹只覆盖开头；保持前缀、inode 不变同时修改中部并追加的特殊重写可能不被识别，可退出应用删除索引后重建。
- 不估算费用，不读取模型价格，不把 token 总数推算成订阅额度百分比。格式错误、不可读文件显示部分数据提示；未找到源目录显示 `—`。

Local logs are not billing records and cannot recover missing, remote, or unwritten usage. Legacy forks without parent logs or inheritance boundaries may retain duplicates, with an in-app warning. Identical cross-session signatures could rarely represent distinct requests and be undercounted. Unusual middle-of-file edits combined with append operations may evade the prefix check; rebuilding the index resolves that case. No costs, prices, or quota-percent conversions are estimated. Invalid/unreadable data is marked partial; a missing source directory displays `—`.

## 验证 / Verification

自动化使用临时合成日志，覆盖累计/单次计数、重复快照、缓存与推理子集、归档副本、子任务边界、旧版 fork、父日志缺失、增量续读、末尾半行、重写/删除、索引持久化和权限、时区及夏令时。截图只使用演示数据。

Tests use temporary synthetic logs and cover counters, deduplication, inherited history, missing parents, incremental and partial-line reads, file changes, cache persistence/privacy/permissions, and calendar/DST boundaries. Screenshots use demonstration data only.

# 费用估算 / Cost estimates

「本地 Token」中的金额，是将该时段本机日志用量按标准 API 单价换算成的美元参考值。它与登录账号无关，不是 ChatGPT/Codex 订阅账单、实际 API 扣费或额度百分比。

Local tokens shows the USD equivalent of retained local usage at standard API rates, independent of the signed-in account. It is not a subscription bill, actual API charge, or quota percentage.

## 内置价格 / Bundled rates

核对日期 / Checked: **2026-09-06**。价格随应用版本更新；离线使用内置快照，不自动下载价格。所有历史都按此快照重算，不回放每个历史日期的旧价格。

The app ships an offline price snapshot, updated with app releases. All history is valued using this snapshot, rather than the rates that applied on each historical date.

单位：USD / 百万 tokens。下表为标准短上下文单价，模型名链接到对应官方来源；[完整官方价格表](https://developers.openai.com/api/docs/pricing)。

USD per million tokens, standard short-context rates. Model links point to official sources.

| 模型 / Model | 普通输入 / Input | 缓存读取 / Cached | 缓存写入 / Writes | 输出 / Output |
| --- | ---: | ---: | ---: | ---: |
| [gpt-6-astra](https://developers.openai.com/api/docs/models/gpt-6-astra) | 10 | 1 | 12.5 | 50 |
| [gpt-5.6-sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol) / gpt-5.6 | 4 | 0.4 | 5 | 20 |
| [gpt-5.6-terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra) | 2 | 0.2 | 2.5 | 12 |
| [gpt-5.6-luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna) | 0.2 | 0.02 | 0.25 | 1.2 |
| [gpt-5.5](https://developers.openai.com/api/docs/models/gpt-5.5) | 5 | 0.5 | — | 30 |
| [gpt-5.4](https://developers.openai.com/api/docs/models/gpt-5.4) | 2.5 | 0.25 | — | 15 |
| [gpt-5.4-mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini) | 0.75 | 0.075 | — | 4.5 |
| [gpt-5.3-codex](https://developers.openai.com/api/docs/models/gpt-5.3-codex) | 1.75 | 0.175 | — | 14 |
| [gpt-5.2-codex](https://developers.openai.com/api/docs/models/gpt-5.2-codex) | 1.75 | 0.175 | — | 14 |
| [gpt-5.1-codex-max](https://developers.openai.com/api/docs/models/gpt-5.1-codex-max) | 1.25 | 0.125 | — | 10 |
| [gpt-5-codex](https://developers.openai.com/api/docs/models/gpt-5-codex) | 1.25 | 0.125 | — | 10 |

GPT-5.6 Sol 当前为促销单价，官方说明至少持续到 2026-11-21；之后使用此版本时请核对官方价格。

GPT-5.6 Sol uses the published promotional rate, available at least through 2026-11-21. Recheck official prices when using this version after that period.

## 如何计算 / Calculation

```text
普通输入 = 输入总量 - 缓存读取 - 缓存写入
费用 = (普通输入 × 输入单价
      + 缓存读取 × 缓存读取单价
      + 缓存写入 × 缓存写入单价
      + 输出 × 输出单价) / 1,000,000
```

Uncached input excludes cache reads and writes. Each category is multiplied by its own per-million rate and summed. Reasoning tokens are included in output and never charged again.

- 对 Astra 与 5.6 系列，单条用量的输入超过 272,000 时，输入、缓存读写采用 2 倍单价，输出采用 1.5 倍。
- 对 5.4 / 5.5，使用同一会话、同一模型中保留的记录判断长上下文；只要有输入超过 272,000 的记录，该组使用长上下文单价。跨时段保留的历史也参与判断。
- 单条用量通常来自 `last_token_usage`，缺失时采用累计差值，可能不能完全还原实际请求。会话长上下文判断依赖本机保留日志，不能恢复缺失的计费上下文。

Astra and GPT-5.6 records above 272K input tokens use 2× input/cache and 1.5× output rates. GPT-5.4/5.5 use the same multipliers across retained records of the same session and model if any record crosses the threshold, including history outside the selected period. Cumulative-delta fallback and missing session records may not reconstruct exact request/billing context.

## 缺价与限制 / Coverage and limits

- 模型名严格匹配；只支持已核对的名称和 `gpt-5.6` 别名，不猜测 Spark、Pro、自定义模型或未知日期快照的价格。
- Spark 未查到公开标准 API 单价。无价格时显示「价格未知」；混合用量显示「已知部分」和未计价 token 数。缺少缓存写入单价但实际有写入量时，该条记录也不计入金额。`—` 不是免费。
- 悬停总金额可看费用分类；悬停柱形可看该时段金额；模型列表包含各模型金额。小于一美分显示 `<$0.01`。
- 不考虑 Fast/Priority、Batch/Flex、地区处理附加费、工具费用、税费、合同折扣、订阅包含额度或历史价格变动。这里始终使用**标准 API 等值**，不能用于账单核对。
- 用量数据仍只在本机。计算费用不访问网络；只有用户主动点击「价格表」才用默认浏览器打开官方页面。

Model matching is exact; Spark, Pro, custom models, and unknown snapshots are not silently mapped to another rate. Missing prices show “Price unknown”; mixed usage shows “Known part” and excluded token counts. Events with cache writes but no verified write rate are also excluded. Hover for category/bucket costs. Amounts below one cent show `<$0.01`.

Fast/Priority, Batch/Flex, regional uplifts, tools, taxes, contracts, included subscription usage, and historical price changes are not applied. These are standard API equivalents, not invoice reconciliation. All calculations stay offline; only explicitly clicking “Price table” opens the official website.

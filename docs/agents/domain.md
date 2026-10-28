# 领域文档

说明工程技能在探索代码库时应如何读取本仓库的领域文档。

## 语言规则

Issue、Spec、Ticket、GLOSSARY 与 ADR 一律使用中文编写与维护；仅代码标识符、日志 JSON 键名、Git 标签与 CLI 命令保留英文原名。

## 探索前先读这些

- 根目录的 `GLOSSARY.md`；或
- 根目录的 `GLOSSARY-MAP.md`（若存在）：它指向每个上下文各自的 `GLOSSARY.md`。阅读所有与当前主题相关的文件。
- `docs/adr/`：阅读与即将改动的领域相关的 ADR。多上下文仓库中，还要检查 `src/<context>/docs/adr/` 下的上下文级决策。

如果这些文件不存在，**静默继续**。不要提示缺失，也不要主动建议创建；`/domain-modeling` 技能（通过 `/grill-with-docs` 与 `/improve-codebase-architecture` 触达）只会在术语或决策真正确定时按需创建。

## 文件结构

单上下文仓库（最常见）：

```
/
├── GLOSSARY.md
├── docs/adr/
│   ├── 0001-*.md
│   └── 0002-*.md
└── PostureLab/
```

多上下文仓库（存在 `GLOSSARY-MAP.md`）：

```
/
├── GLOSSARY-MAP.md
├── docs/adr/                          ← 系统级决策
└── src/
    ├── ordering/
    │   ├── GLOSSARY.md
    │   └── docs/adr/                  ← 上下文级决策
    └── billing/
        ├── GLOSSARY.md
        └── docs/adr/
```

## 使用词汇表的词汇

当输出需要命名领域概念时（Issue 标题、重构提案、假设、测试名），使用 `GLOSSARY.md` 中定义的术语。不要漂移到词汇表明确避免的同义词。

如果需要的新概念尚未进入词汇表，这是一个信号：要么你在发明项目并不使用的语言（重新考虑），要么存在真实缺口（记下来交给 `/domain-modeling`）。

## 标记 ADR 冲突

如果你的输出与现有 ADR 冲突，明确指出来，而不是悄悄覆盖：

> _与 ADR-0007（事件溯源订单）冲突，但值得重新开启，因为……_

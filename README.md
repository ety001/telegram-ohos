# telegram-ohos

鸿蒙原生 Telegram 客户端（个人自用，不上架应用市场）。

- 技术栈：ArkTS / ArkUI (API 26, 三形态自适应) + TDLib (libtdjson) + NAPI 桥
- 目标设备：HarmonyOS 7 全家桶——PC / 手机 / 平板（真机均为 API 26）
- 状态：✅ M0-M4 已完成（工程骨架 / TDLib 交叉编译 + NAPI 桥 / 登录与会话列表 / 消息收发 + 媒体 + 本地通知 / 双端保活，PR #1-#10）；✅ M5 打磨（消息富文本渲染、会话操作菜单、复审遗留修复）；待真机验证清单见 [docs/PLAN.md](docs/PLAN.md)（各里程碑挂账的实测项）

## 文档

| 文档 | 内容 |
|---|---|
| [docs/PLAN.md](docs/PLAN.md) | 开发计划：里程碑、验收标准、风险清单 |
| [docs/RESEARCH.md](docs/RESEARCH.md) | 调研报告：TDLib 移植可行性、鸿蒙平台能力与限制 |
| [docs/CI-RESEARCH.md](docs/CI-RESEARCH.md) | CI 编译迁移调研：双轨方案、GitHub Actions workflow 设计 |
| [AGENTS.md](AGENTS.md) | 工程约定：提交规范、脱敏规则、构建注意 |

## License

本项目基于 [Apache License 2.0](LICENSE) 开源，版权所有 © 2026 ety001；第三方组件声明见 [NOTICE](NOTICE) 与 [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES)。

## 声明

> **Unofficial Telegram client for HarmonyOS.** Not affiliated with, or endorsed by, Telegram Messenger Inc. "Telegram" is a trademark of its respective owner.

本项目面向个人自用场景开发。Telegram 是 Telegram Messenger Inc. 的商标，本项目与其无关联、未获官方认可；应用标题不含官方商标要求所允许之外的表述，如未来公开发布，将遵循 Telegram API 服务条款（"Unofficial" 前缀或改名、不使用官方 logo、使用自申请的 api_id）。

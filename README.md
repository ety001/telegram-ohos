# telegram-ohos

鸿蒙原生 Telegram 客户端（个人自用，不上架应用市场）。

- 技术栈：ArkTS / ArkUI (API 26, 三形态自适应) + TDLib (libtdjson) + NAPI 桥
- 目标设备：HarmonyOS 7 全家桶——PC / 手机 / 平板（真机均为 API 26）
- 状态：🚧 M0 工程骨架已完成（PR #1）；M1 TDLib 交叉编译复审中；deviceTypes 三形态自 M2 落地

## 文档

| 文档 | 内容 |
|---|---|
| [docs/PLAN.md](docs/PLAN.md) | 开发计划：里程碑、验收标准、风险清单 |
| [docs/RESEARCH.md](docs/RESEARCH.md) | 调研报告：TDLib 移植可行性、鸿蒙平台能力与限制 |
| [AGENTS.md](AGENTS.md) | 工程约定：提交规范、脱敏规则、构建注意 |

## 声明

本项目仅供作者本人学习与使用，不分发、不发布。Telegram 是 Telegram Messenger Inc. 的商标，本项目与其无关联。

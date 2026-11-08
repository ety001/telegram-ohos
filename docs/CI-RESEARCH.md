# CI 编译迁移调研（2026-11）

> 结论：**双轨可行且推荐**——GitHub Actions 编译为主 + 本机鸿蒙 PC 兜底。本调研回答"TDLib 编译别再让鸿蒙 PC 风扇狂转 65 分钟"的问题。

## 一、推荐方案与理由

**双轨（CI 为主 + 本机兜底）**；若未来有闲置 x64 Linux 服务器，升级为 self-hosted runner 版双轨（服务器性能 + 持久 ccache + Actions 编排回库，一鱼两吃）。

- 私有库 `ubuntu-latest` runner 规格 **2 vCPU / 8GB / 14GB SSD**（公共库才是 4C/16G），TDLib 单目标全量预计 30~50 分钟；单 job 上限 6h、Free 账号每月约 2000 分钟 Linux 算力（≈40~60 次全量），对手动触发的低频重编绰绰有余。
- 不选纯自有服务器：编译触发—产物回库的自动化链路要自建，单人维护成本不划算。
- 不选纯 CI 撤掉本机：断网/CI 故障/紧急 hotfix 时本机兜底零成本，真机侧载调试也在本机。

## 二、x64 工具链获取（linux-x64 host 编 aarch64-linux-ohos 目标）

| 渠道 | 说明 |
|---|---|
| 华为云官方直链（推荐，免登录） | `https://repo.huaweicloud.com/openharmony/os/7.0-Release/ohos-sdk-windows_linux-public.tar.gz`（3.2GiB，含 windows+linux 全组件；**OpenHarmony 7.0 = API 26，与 HarmonyOS 7 对齐**） |
| GitHub 镜像 | [openharmony-rs/ohos-sdk releases](https://github.com/openharmony-rs/ohos-sdk/releases)（>2GB 自动分卷，cat 合并；GH runner 下载更快） |
| 现成安装 Action | [openharmony-rs/setup-ohos-sdk](https://github.com/openharmony-rs/setup-ohos-sdk)（支持 4.0→7.0/API 26，内置 cache）、[isaced/setup-ohos](https://github.com/isaced/setup-ohos)（华为云直链 + OHOS_NDK_HOME 变量） |

只需解压 linux 侧 `native-linux-x64-*.zip`（约 2~3GB），windows 分量删除。注意 `ohos.toolchain.cmake` 位置随 SDK 版本在 `native/build/cmake/` 与 `native/build-tools/cmake/` 之间变化，脚本需双路径探测。

## 三、workflow 骨架（.github/workflows/build-tdlib.yml）

```yaml
on:
  workflow_dispatch: { inputs: { sdk_version: { default: "7.0" } } }
  push: { tags: ["tdlib-v*"] }
concurrency: { group: build-tdlib, cancel-in-progress: true }
jobs:
  build:
    runs-on: ubuntu-latest          # 未来可换 [self-hosted, linux, x64]
    timeout-minutes: 90
    env:
      OHOS_SDK_VER: "7.0"
      OHOS_SDK_HOME: ${{ github.workspace }}/ohos-sdk/linux
    steps:
      - uses: actions/checkout@v6
      - uses: endersonmenezes/free-disk-space@v3   # runner 仅 14GB，保险
      - run: sudo apt-get install -y build-essential gperf ninja-build ccache unzip
      - uses: hendrikmuhs/ccache-action@v1.2
        with: { max-size: "5G" }
      - uses: actions/cache@v4
        id: sdk
        with: { path: ${{ env.OHOS_SDK_HOME }}, key: ohos-sdk-${{ env.OHOS_SDK_VER }} }
      - if: steps.sdk.outputs.cache-hit != 'true'
        run: |
          curl -OL https://repo.huaweicloud.com/openharmony/os/${OHOS_SDK_VER}-Release/ohos-sdk-windows_linux-public.tar.gz
          tar -xzf ohos-sdk-*.tar.gz && rm ohos-sdk-*.tar.gz && rm -rf ohos-sdk/{ohos,windows}
          (cd ohos-sdk/linux && for z in *.zip; do unzip -q "$z" && rm "$z"; done)
      - run: ./scripts/build_tdlib.sh --sdk "$OHOS_SDK_HOME" --jobs "$(nproc)" --ccache
      - name: 产物回库
        run: |
          cp out/libtdjson.so libs/arm64-v8a/libtdjson.so
          cp out/SHA256SUMS libs/arm64-v8a/SHA256SUMS
          git config user.name github-actions[bot]
          git config user.email 41898602+github-actions[bot]@users.noreply.github.com
          git add libs/arm64-v8a && git commit -m "chore(tdlib): rebuild libtdjson.so [skip ci]" && git push
      - uses: actions/upload-artifact@v4
        with: { name: libtdjson-ohos, path: out/, retention-days: 7 }
```

要点：`[skip ci]` 防递归触发；产物回库用 **bot commit 范式**（tdlib-android 先例）；LTO 场景需加 10GB swap（`pierotofy/set-swap-space`，链接期内存峰值）——当前未开 LTO 可不加。

## 四、build_tdlib.sh 三端参数化收口清单

1. `--sdk <path>` / `OHOS_NDK_HOME` 环境变量为唯一 SDK 入口（内含 native/）；删除 `$HOME`/harmonybrew 硬编码默认值改为可覆盖参数
2. toolchain 双路径探测（native/build/cmake 与 native/build-tools/cmake）
3. `--jobs` 默认 nproc；`--ccache` 开关（`CMAKE_C(XX)_COMPILER_LAUNCHER=ccache`）；`--clean` 子命令
4. `--out <dir>` 输出到 staging，由调用方决定 commit 目标
5. strip 固定用 SDK 内 `native/llvm/bin/llvm-strip --strip-unneeded`（三端同一工具同一参数）
6. 鸿蒙 PC 特有问题（uname-is-linux LD_PRELOAD 等）只影响 hvigor/HAP 链路，不影响 cmake 交叉编译，无需分叉

## 五、风险与注意

1. 两端 clang 小版本差异 → 产物 sha256 天然不同，验收标准是"功能等价 + 权威链路自洽"，非跨端字节一致；建议固定"一条产物权威链路"（推荐 CI），另一端仅兜底
2. 34MB 二进制反复入库 git 历史持续膨胀 → 中期可考虑 LFS 或"库内留最新 + 历史进 Release"
3. runner 磁盘 14GB：务必 free-disk-space 或只解 linux 组件
4. gperf/cmake/ninja 等 host 工具：CI 里 apt 装；本机 harmonybrew 已有

## 六、关键参考

- OpenBLAS OHOS CI 模板：https://github.com/OpenMathLib/OpenBLAS/blob/develop/.github/workflows/harmonyos.yml
- Termony 工程化模板（cache/ccache/磁盘全配齐）：https://github.com/TermonyHQ/Termony/blob/master/.github/workflows/hnp.yml
- TDLib-OHOS 构建脚本（与本仓库同构）：https://github.com/ErBWs/tdlib-ohos-build
- TDLib Android CI 产物回库范式：https://github.com/AkashPriyadarshii/tdlib-android/blob/master/.github/workflows/build.yml
- runner/配额文档：https://docs.github.com/en/actions/reference/runners/github-hosted-runners 、https://docs.github.com/en/actions/reference/limits

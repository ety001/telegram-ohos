/**
 * 托盘图标服务（ServiceExtensionAbility）。
 *
 * 职责：
 *   - 独立于 UIAbility 运行，主窗口关闭后继续存活
 *   - 注册并维护系统托盘（状态栏）图标
 *   - 处理托盘图标点击事件，恢复主窗口
 *
 * 生命周期：
 *   - onCreate: 注册状态栏图标
 *   - onDestroy: 清理（应用真正退出时）
 *   - 图标点击: 通过 wantAgent 拉起 EntryAbility
 */
import { AppServiceExtensionAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { statusBarManager } from '@kit.DeskTopExtensionKit';
import { image } from '@kit.ImageKit';
import { resourceManager } from '@kit.LocalizationKit';

const TAG: string = 'TrayIconService';
const LOG_DOMAIN: number = 0x0013;

export default class TrayIconService extends AppServiceExtensionAbility {
  private context: common.AppServiceExtensionContext | null = null;

  onCreate(want: Want): void {
    hilog.info(LOG_DOMAIN, TAG, 'onCreate');
    this.context = this.context;
    // 延迟注册：确保资源就绪
    setTimeout(() => {
      this.registerStatusBarIcon();
    }, 500);
  }

  onDestroy(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onDestroy');
    // 应用真正退出时清理（系统会自动移除图标）
    this.context = null;
  }

  onStart(want: Want): void {
    hilog.info(LOG_DOMAIN, TAG, 'onStart');
  }

  onStop(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onStop');
  }

  /** 注册系统托盘图标 */
  private async registerStatusBarIcon(): Promise<void> {
    try {
      const ctx: common.AppServiceExtensionContext | null = this.context;
      if (!ctx) {
        hilog.error(LOG_DOMAIN, TAG, 'context is null');
        return;
      }
      const resourceMgr: resourceManager.ResourceManager = ctx.resourceManager;
      // 获取白色图标（深色背景用）
      const whiteData: Uint8Array = resourceMgr.getRawFileContentSync('statusbar_white.png');
      const whiteSource: image.ImageSource = image.createImageSource(whiteData.buffer as ArrayBuffer);
      const whitePixelMap: image.PixelMap = await whiteSource.createPixelMap();
      // 获取黑色图标（浅色背景用）
      const blackData: Uint8Array = resourceMgr.getRawFileContentSync('statusbar_black.png');
      const blackSource: image.ImageSource = image.createImageSource(blackData.buffer as ArrayBuffer);
      const blackPixelMap: image.PixelMap = await blackSource.createPixelMap();
      // 构建状态栏图标配置
      const statusBarItem: statusBarManager.StatusBarItem = {
        icons: {
          white: whitePixelMap,
          black: blackPixelMap
        },
        quickOperation: {
          abilityName: 'EntryAbility',  // 点击拉起主窗口
          title: 'Telegram',
          height: 200,
          moduleName: 'entry'
        },
        hoverTips: 'Telegram - 点击打开'
      };
      // 使用 ServiceExtensionContext 注册（独立于 UIAbility）
      statusBarManager.addToStatusBar(ctx, statusBarItem);
      hilog.info(LOG_DOMAIN, TAG, 'status bar icon registered by TrayIconService');
    } catch (err) {
      hilog.error(LOG_DOMAIN, TAG, 'registerStatusBarIcon failed: %{public}s', JSON.stringify(err));
    }
  }
}

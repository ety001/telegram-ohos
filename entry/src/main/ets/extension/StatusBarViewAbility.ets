/**
 * 状态栏扩展 Ability（系统托盘图标）。
 *
 * 功能：
 *   - 在 HarmonyOS PC 系统托盘（状态栏右侧）显示应用图标
 *   - 点击图标恢复窗口到前台（如果窗口被销毁则重新创建）
 *   - 配合 KeepAliveService 实现后台保活 + 通知
 *
 * 系统能力：SystemCapability.PCService.StatusBarManager
 * 起始版本：5.0.0(12)
 * 参考：@kit.DeskTopExtensionKit StatusBarViewExtensionAbility
 */
import { StatusBarViewExtensionAbility } from '@kit.DeskTopExtensionKit';
import { UIExtensionContentSession, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const TAG: string = 'StatusBarView';
const LOG_DOMAIN: number = 0x0011;

export default class TelegramStatusBarAbility extends StatusBarViewExtensionAbility {
  private session: UIExtensionContentSession | null = null;

  onCreate(): void {
    hilog.info(LOG_DOMAIN, TAG, 'StatusBarViewAbility: onCreate');
  }

  onDestroy(): void {
    hilog.info(LOG_DOMAIN, TAG, 'StatusBarViewAbility: onDestroy');
    this.session = null;
  }

  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    hilog.info(LOG_DOMAIN, TAG, 'onSessionCreate, want: %{public}s', JSON.stringify(want));
    this.session = session;
    // 加载状态栏图标页面（可以是简单的占位页面或空内容）
    session.loadContent('pages/StatusBarPage');
  }

  onSessionDestroy(session: UIExtensionContentSession): void {
    hilog.info(LOG_DOMAIN, TAG, 'onSessionDestroy');
    if (this.session === session) {
      this.session = null;
    }
  }

  onForeground(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onForeground - status bar icon clicked!');
    // 点击托盘图标时，恢复或重新创建主窗口
    this.restoreMainWindow();
  }

  onBackground(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onBackground');
  }

  /** 恢复主窗口到前台（如果窗口被销毁则重新创建） */
  private restoreMainWindow(): void {
    try {
      // 方法1：尝试查找并显示已存在的窗口
      const mainWindow: window.Window | undefined = window.findWindow('main');
      if (mainWindow) {
        mainWindow.showWindow();
        hilog.info(LOG_DOMAIN, TAG, 'main window restored (showWindow)');
        return;
      }
      // 方法2：窗口已被销毁，重新启动 EntryAbility 创建新窗口
      hilog.info(LOG_DOMAIN, TAG, 'main window not found - restarting EntryAbility');
      const want: Want = {
        bundleName: 'com.ety001.telegramohos',
        abilityName: 'EntryAbility',
        moduleName: 'entry'
      };
      this.context.startAbility(want)
        .then(() => hilog.info(LOG_DOMAIN, TAG, 'EntryAbility restarted'))
        .catch((err: Error) => hilog.error(LOG_DOMAIN, TAG, 'restart failed: %{public}s', JSON.stringify(err)));
    } catch (err) {
      hilog.error(LOG_DOMAIN, TAG, 'restoreMainWindow failed: %{public}s', JSON.stringify(err));
    }
  }
}

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ConfigStore } from '../core/ConfigStore';
import { TdClient } from '../tdlib/TdClient';
import { BreakpointTool } from '../core/BreakpointTool';
import { NotificationService } from '../core/NotificationService';
import { KeepAliveService } from '../core/KeepAliveService';
import { statusBarManager } from '@kit.DeskTopExtensionKit';
import { image } from '@kit.ImageKit';

const TAG: string = 'EntryAbility';
const LOG_DOMAIN: number = 0x0011;

export default class EntryAbility extends UIAbility {
  /** 主窗口 Stage（onPrepareToTerminate 最小化用） */
  private mainWindowStage: window.WindowStage | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(LOG_DOMAIN, TAG, 'onCreate, action: %{public}s', want.action ?? '');
    // 配置存储初始化（凭证/代理），先于任何页面使用
    ConfigStore.init(this.context);
    // 通知服务接线：UIAbilityContext（授权弹窗）+ bundleName（点击路由 wantAgent）；
    // 冷启动点击通知时 want.parameters 带 chatId，暂存待 Index 就绪后路由
    NotificationService.getInstance().attach(this.context);
    NotificationService.getInstance().handleLaunchWant(want);
    // 保活服务接线：上下文（长时任务申请）+ bundleName（通知点击拉起）+ 登录态观察（后台被登出自愈释放）
    KeepAliveService.getInstance().attach(this.context);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 通知点击（应用存活，singleton 启动模式不重建）：wantAgent 的 START_ABILITY 走此回调
    NotificationService.getInstance().handleLaunchWant(want);
  }

  onDestroy(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onDestroy - app quit');
    // 走到这里都是真实退出（关闭按钮已被 onPrepareToTerminate 拦截，不会触发 onDestroy）
    KeepAliveService.getInstance().stopKeepAlive();
    TdClient.getInstance().dispose();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(LOG_DOMAIN, TAG, 'onWindowStageCreate');
    // 保存主窗口引用（关闭拦截最小化用）
    this.mainWindowStage = windowStage;
    // 保存到 AppStorage 供页面层最小化按钮使用
    AppStorage.setOrCreate('windowStage', windowStage);
    // 断点初值先于首页 loadContent 就绪（Index aboutToAppear 即可读到真实断点）
    BreakpointTool.getInstance().attach(windowStage);
    // 注意：不注册 windowStageClose 监听！
    // 因为注册后会导致 onPrepareToTerminate 不再被调用（官方文档明确说明）
    // 窗口关闭拦截完全依赖 onPrepareToTerminate 返回 true
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(LOG_DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(LOG_DOMAIN, TAG, 'loadContent succeeded');
      // 注册系统托盘图标（状态栏扩展）
      this.registerStatusBarIcon();
    });
  }

  /** 注册系统托盘（状态栏）图标 */
  private async registerStatusBarIcon(): Promise<void> {
    try {
      const resourceMgr = this.context.resourceManager;
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
          abilityName: '',  // 空字符串：不显示弹窗，用事件监听处理点击
          title: 'Telegram',
          height: 200,
          moduleName: 'entry'
        },
        hoverTips: 'Telegram - 点击打开'
      };
      // 说明：不配置 statusBarGroupMenu。系统会在托盘右键菜单自动追加「退出」项
      // （官方指南：该系统项不支持应用自定义），点击走 EntryAbilityStage.onPrepareTermination 真正退出。
      // 调用 API 添加到状态栏
      statusBarManager.addToStatusBar(this.context, statusBarItem);
      // 注册托盘图标点击监听：quickOperation.abilityName 为空时，
      // 点击事件必须通过 statusBarIconClick 事件处理（官方文档要求）
      statusBarManager.on('statusBarIconClick', () => {
        hilog.info(LOG_DOMAIN, TAG, 'status bar icon clicked, show main window');
        this.showMainWindow();
      });
      hilog.info(LOG_DOMAIN, TAG, 'status bar icon registered successfully');
    } catch (err) {
      hilog.error(LOG_DOMAIN, TAG, 'registerStatusBarIcon failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 显示主窗口（从托盘恢复）。最小化前的位置/大小由窗口管理器保留，无需手动还原 */
  showMainWindow(): void {
    if (this.mainWindowStage !== null) {
      try {
        const mainWindow: window.Window = this.mainWindowStage.getMainWindowSync();
        mainWindow.showWindow();
        hilog.info(LOG_DOMAIN, TAG, 'main window shown (restored from tray)');
      } catch (err) {
        hilog.error(LOG_DOMAIN, TAG, 'showMainWindow failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onForeground');
    // 前台：正打开的会话视为「用户正在看」不通知；顺带自愈通知授权状态
    NotificationService.getInstance().setForeground(true);
    // 回前台释放保活长时任务：前台不挂起无需保活，且长挂与业务不符易触发系统一致性管控
    // （NotificationService 的回前台自愈逻辑不在此处，保持不动）
    KeepAliveService.getInstance().stopKeepAlive();
  }

  onBackground(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onBackground');
    // 后台：新消息（含正打开会话）恢复通知
    NotificationService.getInstance().setForeground(false);
    // 进后台申请保活长时任务（TASK_KEEPING）保 TDLib 长连接；ready 登录态才申请（服务内判定）
    KeepAliveService.getInstance().startKeepAlive();
  }

  /**
   * 拦截窗口 X 按钮关闭（托盘/任务栏右键退出已分流至 EntryAbilityStage.onPrepareTermination）。
   * 返回 true 阻止关闭，最小化窗口；进程与 TDLib 继续运行，托盘图标保留。
   * 点击托盘图标触发 statusBarIconClick → showMainWindow() 恢复窗口。
   */
  onPrepareToTerminate(): boolean {
    hilog.info(LOG_DOMAIN, TAG, 'onPrepareToTerminate: called! → will minimize window to tray');
    if (this.mainWindowStage !== null) {
      try {
        const mainWindow: window.Window = this.mainWindowStage.getMainWindowSync();
        mainWindow.minimize();
        hilog.info(LOG_DOMAIN, TAG, 'window minimized to taskbar');
      } catch (err) {
        hilog.error(LOG_DOMAIN, TAG, 'minimize failed: %{public}s', JSON.stringify(err));
      }
    }
    return true;  // 返回 true 阻止关闭
  }
}

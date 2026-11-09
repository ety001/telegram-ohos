import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ConfigStore } from '../core/ConfigStore';
import { TdClient } from '../tdlib/TdClient';
import { BreakpointTool } from '../core/BreakpointTool';
import { NotificationService } from '../core/NotificationService';

const TAG: string = 'EntryAbility';
const LOG_DOMAIN: number = 0x0011;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(LOG_DOMAIN, TAG, 'onCreate, action: %{public}s', want.action ?? '');
    // 配置存储初始化（凭证/代理），先于任何页面使用
    ConfigStore.init(this.context);
    // 通知服务接线：UIAbilityContext（授权弹窗）+ bundleName（点击路由 wantAgent）；
    // 冷启动点击通知时 want.parameters 带 chatId，暂存待 Index 就绪后路由
    NotificationService.getInstance().attach(this.context);
    NotificationService.getInstance().handleLaunchWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 通知点击（应用存活，singleton 启动模式不重建）：wantAgent 的 START_ABILITY 走此回调
    NotificationService.getInstance().handleLaunchWant(want);
  }

  onDestroy(): void {
    // TDLib 收尾：发送 close + 停接收线程（NAPI 复审遗留落地）
    TdClient.getInstance().dispose();
    hilog.info(LOG_DOMAIN, TAG, 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(LOG_DOMAIN, TAG, 'onWindowStageCreate');
    // 断点初值先于首页 loadContent 就绪（Index aboutToAppear 即可读到真实断点）
    BreakpointTool.getInstance().attach(windowStage);
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(LOG_DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(LOG_DOMAIN, TAG, 'loadContent succeeded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onForeground');
    // 前台：正打开的会话视为「用户正在看」不通知；顺带自愈通知授权状态
    NotificationService.getInstance().setForeground(true);
  }

  onBackground(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onBackground');
    // 后台：新消息（含正打开会话）恢复通知
    NotificationService.getInstance().setForeground(false);
  }
}

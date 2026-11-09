import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ConfigStore } from '../core/ConfigStore';
import { TdClient } from '../tdlib/TdClient';
import { BreakpointTool } from '../core/BreakpointTool';
import { NotificationService } from '../core/NotificationService';
import { KeepAliveService } from '../core/KeepAliveService';

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
    // 保活服务接线：上下文（长时任务申请）+ bundleName（通知点击拉起）+ 登录态观察（后台被登出自愈释放）
    KeepAliveService.getInstance().attach(this.context);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 通知点击（应用存活，singleton 启动模式不重建）：wantAgent 的 START_ABILITY 走此回调
    NotificationService.getInstance().handleLaunchWant(want);
  }

  onDestroy(): void {
    // 保活收尾：销毁即释放长时任务（撤常驻通知；进程被杀时系统亦会清理，此处为正常退出的整洁路径）
    KeepAliveService.getInstance().stopKeepAlive();
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
}

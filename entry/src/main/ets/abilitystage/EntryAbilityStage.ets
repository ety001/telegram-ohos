/**
 * AbilityStage 组件管理器（Module 级）。
 *
 * 职责：
 *   - 接管「托盘/任务栏右键退出」「设备关机」等系统退出场景：
 *     实现 onPrepareTermination 后，这些场景不再走 UIAbility.onPrepareToTerminate，
 *     与「X 按钮关闭 → 最小化到托盘」彻底分流（官方 FAQ 明确说明）。
 *
 * 系统能力：SystemCapability.Ability.AbilityRuntime.Core
 * 起始版本：API 15，仅 PC/2in1（API 19 起含 Tablet）回调
 * 需要权限：ohos.permission.PREPARE_APP_TERMINATE（module.json5 已声明）
 */
import { AbilityConstant, AbilityStage } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'EntryAbilityStage';
const LOG_DOMAIN: number = 0x0011;

export default class EntryAbilityStage extends AbilityStage {
  /**
   * 用户通过托盘/任务栏右键「退出」或设备关机关闭应用时触发。
   * 用户明确要求退出 → 返回 TERMINATE_IMMEDIATELY 立即结束；
   * 托盘图标、长时任务随进程销毁由系统自动回收，TDLib 在 UIAbility.onDestroy 释放。
   */
  onPrepareTermination(): AbilityConstant.PrepareTermination {
    hilog.info(LOG_DOMAIN, TAG, 'onPrepareTermination: user exit (tray/taskbar/shutdown) → terminate immediately');
    return AbilityConstant.PrepareTermination.TERMINATE_IMMEDIATELY;
  }
}

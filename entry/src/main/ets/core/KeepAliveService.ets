/**
 * 保活服务（M4，PLAN §5「双端后台与保活」）。单例。
 *
 * 背景：deviceTypes 含 phone 后（2026-04 决策），PC 端最小化同样触发后台管控，
 * 双端保活统一依赖 @ohos.backgroundTaskManager 长时任务（continuous task）——
 * 官方契约：一个 UIAbility 申请长时任务成功后「整个应用下的所有进程均不会被挂起」，
 * TDLib 的 native 接收线程/网络线程同在此保护面内（无需也不能对 .so 线程单独申请）。
 *
 * 任务类型取舍（TASK_KEEPING，查 API 26 SDK @ohos.resourceschedule.backgroundTaskManager.d.ts）：
 * - PC/2in1：TASK_KEEPING（计算任务）免 ACL，仅需 M0 已声明的 KEEP_BACKGROUND_RUNNING，
 *   这是 PC 端最小化保长连接的主路径（PLAN 调研结论）。
 * - 手机端：TASK_KEEPING 自 API 21 起对非 PC/2in1 设备要求系统 ACL
 *   （ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM），本项目未申请（红线：权限无新增），
 *   申请预期被 9800005 拒绝（错误码分类见 applyStartFailure）。若个别版本/渠道灰度放行，
 *   其语义仍为「计算任务」（官方场景举例：杀毒软件），长连接保活与申请类型不完全相符——
 *   系统一致性校验（申请类型与实际业务不符/业务已结束）存在被查杀/取消的风险，属灰度用法，
 *   不可作为长期依赖；手机端实测结论与备选方案评估见 docs/PLAN.md M4。
 *
 * 通知：长时任务申请成功后由系统自动挂常驻通知（无提示音），应用侧不手动 publish；
 * 点击通知经 wantAgent（START_ABILITY → EntryAbility，singleton）回到应用主界面。
 *
 * 状态机（单槽位：官方约束一个 UIAbility 同一时刻仅一个长时任务）：
 *   IDLE（未申请）→ STARTING（申请中）→ RUNNING（已申请，常驻通知在挂）
 *   startKeepAlive 幂等（非 IDLE 直接返回）；stopKeepAlive 幂等（非 RUNNING 直接返回，
 *   STARTING 在途时挂 pendingStop，申请落定后立即释放——覆盖「onBackground 后紧接 onDestroy」时序）。
 *
 * 错误码处理清单（官方错误码表 9800001~9800007 + 通用 401/201；无 10200005——
 * 该码属语言基础类库（utils），与本模块无关）：
 *   9800005 校验失败：手机端设备类型不允许 TASK_KEEPING / bgMode 未配置 / 重复申请 / 重复取消。
 *     start 侧命中 → 判定为确定性拒绝：置 IDLE + 拒绝闩锁（本进程不再自动撞墙，避免每次切后台
 *     反复失败调用），并补一次对冲 stop 清理系统侧可能的残留任务（吞错）；同时记录 deviceType
 *     供真机实测定位。stop 侧命中（重复取消）→ 视为已释放，静默归 IDLE。
 *   9800001/9800002/9800003/9800004/9800006/9800007 系统侧瞬态/环境故障 → 置 IDLE 告警，
 *     不闩锁：下次进后台自然重试（频率 = 用户切后台频率，无重试风暴）。
 *   401 参数错误 / 201 权限拒绝 → 调用侧/配置侧缺陷，置 IDLE 记 error（KEEP_BACKGROUND_RUNNING
 *     M0 已声明，理论不可达，真机命中即查 module.json5 与入参）。
 *   stop 其他失败 → 回滚 RUNNING（任务大概率仍在），下次前后台流转自愈重停。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent, Want, common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { AuthService, AppAuthState, AuthStateObserver } from './AuthService';

const TAG: string = 'KeepAliveService';
const LOG_DOMAIN: number = 0x0012;
/** 点击长时任务通知拉起的目标 ability（module.json5 mainElement） */
const ABILITY_NAME: string = 'EntryAbility';

/** 长时任务状态机 */
class KeepAliveState {
  /** 未申请（初始/已释放/确定性拒绝闩锁后） */
  static readonly IDLE: string = 'idle';
  /** 申请中（startBackgroundRunning 在途） */
  static readonly STARTING: string = 'starting';
  /** 已申请（长时任务生效，系统常驻通知在挂） */
  static readonly RUNNING: string = 'running';
}

/** 本模块相关错误码（官方错误码表 + 通用错误码；区别于语言基础类库的 102000xx 段） */
class BgTaskError {
  /** 通用：参数错误（调用侧缺陷） */
  static readonly PARAM_INVALID: number = 401;
  /** 通用：权限拒绝（KEEP_BACKGROUND_RUNNING 未声明，M0 已声明理论不可达） */
  static readonly PERMISSION_DENIED: number = 201;
  /** 长时任务校验失败（设备类型/bgMode 配置/重复申请取消）——唯一确定性拒绝 */
  static readonly VERIFY_FAILED: number = 9800005;
}

export class KeepAliveService {
  private static instance: KeepAliveService | null = null;

  private state: string = KeepAliveState.IDLE;
  /** 9800005 确定性拒绝后闩锁：本进程内不再自动申请（手机端预期路径），下次冷启动自然重试 */
  private rejected: boolean = false;
  /** STARTING 在途时收到 stop 请求（onBackground 后紧接销毁的时序），申请落定后立即释放 */
  private pendingStop: boolean = false;
  /** EntryAbility.onCreate 接线（申请长时任务 + wantAgent 构建依赖） */
  private abilityContext: common.UIAbilityContext | null = null;
  private bundleName: string = '';
  /** 登出自愈：后台期间 authState 离开 ready（如其他设备登出本会话）即释放长时任务 */
  private authObserved: boolean = false;

  private constructor() {
  }

  static getInstance(): KeepAliveService {
    if (KeepAliveService.instance === null) {
      KeepAliveService.instance = new KeepAliveService();
    }
    return KeepAliveService.instance;
  }

  private readonly authObserver: AuthStateObserver = (appState: string): void => {
    if (appState !== AppAuthState.READY) {
      // 后台期间被登出：登录页无需保活（长连接已无业务语义），立即释放，
      // 避免登录页挂一条「计算任务」常驻通知被一致性校验盯上
      this.stopKeepAlive();
    }
  };

  /** EntryAbility.onCreate 接线：上下文（申请长时任务）与 wantAgent 目标（bundleName），
   *  并订阅登录态（订阅即推当前态，初始 INITIAL 无副作用） */
  attach(context: common.UIAbilityContext): void {
    this.abilityContext = context;
    try {
      this.bundleName = context.abilityInfo.bundleName;
    } catch (err) {
      // 与 NotificationService.attach 同口径：读不到仅降级 wantAgent 定位（点击拉起可能失效），
      // 保活申请本身不受影响
      this.bundleName = '';
      hilog.warn(LOG_DOMAIN, TAG, 'read bundleName failed: %{private}s', JSON.stringify(err));
    }
    if (!this.authObserved) {
      this.authObserved = true;
      AuthService.getInstance().onAuthState(this.authObserver);
    }
  }

  /**
   * 申请保活长时任务（EntryAbility.onBackground 接线，进后台保 TDLib 长连接）。幂等。
   *
   * 仅登录就绪（ready）才申请：未登录/登录流程中退后台没有消息语义，不值得占用长时任务
   * （TDLib 未登录确有连接，但仅为鉴权流，冻结即断也无损失——简化取舍，见 PLAN M4）。
   */
  startKeepAlive(): void {
    if (this.state !== KeepAliveState.IDLE) {
      // STARTING+pendingStop 在途：新 start 意图覆盖旧 stop 意图（M4 复审 LOW 修复：
      // bg→fg→bg 快速流转下，旧 stop 意图不撤销会导致申请成功后被误停）
      if (this.state === KeepAliveState.STARTING && this.pendingStop) {
        this.pendingStop = false;
      }
      return; // 幂等：STARTING/RUNNING 均视为已保活
    }
    if (this.rejected) {
      return; // 确定性拒绝闩锁（手机端 TASK_KEEPING 需系统 ACL）：本进程不再自动撞墙
    }
    if (AuthService.getInstance().getAuthState() !== AppAuthState.READY) {
      return; // 未登录不保活（见方法注释）
    }
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null) {
      return; // 未 attach（防御：EntryAbility.onCreate 先于任何 onBackground）
    }
    this.state = KeepAliveState.STARTING;
    this.buildWantAgent()
      .then((agent: WantAgent): Promise<void> => {
        // 申请成功后系统自动挂常驻通知（无提示音），应用侧不手动 publish
        return backgroundTaskManager.startBackgroundRunning(context,
          backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
      })
      .then((): void => {
        this.state = KeepAliveState.RUNNING;
        hilog.info(LOG_DOMAIN, TAG, 'keep-alive task running');
        if (this.pendingStop) {
          // 申请在途时收到过 stop（onBackground 后紧接销毁）：立即兑现
          this.pendingStop = false;
          this.stopKeepAlive();
        }
      })
      .catch((err: BusinessError): void => {
        this.applyStartFailure(err);
      });
  }

  /**
   * 释放保活长时任务（EntryAbility.onForeground/onDestroy 接线）。幂等。
   *
   * 回前台即释放：前台本就不挂起无需长时任务，且长挂「计算任务」与实际业务（待命长连接）
   * 不符易触发系统一致性管控——按官方建议「任务结束及时取消」，每次进出后台重新申请。
   */
  stopKeepAlive(): void {
    if (this.state === KeepAliveState.STARTING) {
      this.pendingStop = true; // 申请在途：落定后由 startKeepAlive 完成路径兑现
      return;
    }
    if (this.state !== KeepAliveState.RUNNING) {
      return; // 幂等：IDLE 无任务可释放
    }
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null) {
      this.state = KeepAliveState.IDLE; // 防御：无上下文调不了 stop，归位等待进程级清理
      return;
    }
    this.state = KeepAliveState.IDLE;
    backgroundTaskManager.stopBackgroundRunning(context)
      .then((): void => {
        hilog.info(LOG_DOMAIN, TAG, 'keep-alive task stopped');
      })
      .catch((err: BusinessError): void => {
        if (err.code === BgTaskError.VERIFY_FAILED) {
          // 重复取消：任务实际已不在（系统侧清理过），当前 IDLE 即正确终态
          hilog.info(LOG_DOMAIN, TAG, 'stop: already stopped (9800005)');
          return;
        }
        // 其他失败按「任务仍在」回滚 RUNNING，下次前后台流转自愈重停；
        // 若下一轮 start 撞「重复申请」9800005，start 侧对冲 stop 会清掉残留
        this.state = KeepAliveState.RUNNING;
        hilog.warn(LOG_DOMAIN, TAG, 'stop failed, rollback to running: %{public}d', err.code);
      });
  }

  /** 当前是否已申请（诊断/日志用） */
  isRunning(): boolean {
    return this.state === KeepAliveState.RUNNING;
  }

  /** start 失败分类处置（错误码清单见文件头注释） */
  private applyStartFailure(err: BusinessError): void {
    this.state = KeepAliveState.IDLE;
    // 失败即无事可兑现：清 pendingStop（M4 复审 MEDIUM 修复：不清则下一轮后台
    // 申请成功后被陈旧 stop 意图立即误停，本轮后台全程无保活）
    this.pendingStop = false;
    if (err.code === BgTaskError.VERIFY_FAILED) {
      // 确定性拒绝：手机/平板无 TASK_KEEPING ACL（API 21+ 非 PC/2in1 需
      // KEEP_BACKGROUND_RUNNING_SYSTEM）、module.json5 未配置 backgroundModes、
      // 或系统侧残留任务的重复申请。闩锁 + 对冲 stop（清残留，吞错），deviceType 供真机定位
      this.rejected = true;
      hilog.warn(LOG_DOMAIN, TAG,
        'keep-alive rejected (9800005), deviceType=%{public}s — 手机端属预期（TASK_KEEPING 需系统 ACL），本进程不再自动申请',
        deviceInfo.deviceType);
      this.reconcileStop();
      return;
    }
    if (err.code === BgTaskError.PARAM_INVALID || err.code === BgTaskError.PERMISSION_DENIED) {
      // 调用侧/配置侧缺陷：真机命中即查 module.json5（backgroundModes/权限）与入参
      hilog.error(LOG_DOMAIN, TAG, 'keep-alive start invalid: code=%{public}d', err.code);
      return;
    }
    // 9800001~9800004/9800006/9800007 系统侧瞬态故障：不闩锁，下次进后台自然重试
    hilog.warn(LOG_DOMAIN, TAG, 'keep-alive start failed (transient): code=%{public}d', err.code);
  }

  /** 对冲释放：清理系统侧可能残留的长时任务（9800005 重复申请场景），失败吞掉（诊断性调用） */
  private reconcileStop(): void {
    const context: common.UIAbilityContext | null = this.abilityContext;
    if (context === null) {
      return;
    }
    backgroundTaskManager.stopBackgroundRunning(context)
      .then((): void => {
        hilog.info(LOG_DOMAIN, TAG, 'reconcile stop done (stale task cleared)');
      })
      .catch((err: BusinessError): void => {
        hilog.info(LOG_DOMAIN, TAG, 'reconcile stop noop: %{public}d', err.code);
      });
  }

  /** wantAgent：点击长时任务常驻通知回到应用（EntryAbility singleton，无路由参数——回主界面即可）。
   *  同步抛错转 rejection 统一走 applyStartFailure（沿 NotificationService.buildWantAgent 口径） */
  private buildWantAgent(): Promise<WantAgent> {
    const want: Want = {
      bundleName: this.bundleName,
      abilityName: ABILITY_NAME
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      // 11+ 推荐字段：actionType/actionFlags（operationType/wantAgentFlags 已废弃）
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      return wantAgent.getWantAgent(info);
    } catch (err) {
      hilog.warn(LOG_DOMAIN, TAG, 'getWantAgent threw: %{private}s', JSON.stringify(err));
      return new Promise<WantAgent>((resolve: (v: WantAgent) => void,
        reject: (r: BusinessError) => void): void => {
        reject(err as BusinessError);
      });
    }
  }
}

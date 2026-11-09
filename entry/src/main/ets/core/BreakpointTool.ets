/**
 * 响应式断点工具（M2，PLAN §4「UI 响应式」落地）。单例。
 *
 * 断点口径（ArkUI 官方 windowWidth 断点，单位 vp）：
 *   sm <600（手机） / md 600~840（平板竖屏、PC 窄窗） / lg ≥840（PC、平板横屏）
 *
 * 实现：EntryAbility.onWindowStageCreate 时 attach 主窗口，
 * 初值取 windowRect.width（px），随后监听 window.on('windowSizeChange')（px）
 * 以 display.densityPixels 换算 vp —— PC 自由窗口缩放/平板分屏同样实时切断点。
 *
 * 订阅方式与 AuthService 一致：观察者回调（订阅即推送当前值）。
 * 页面侧用 @State 接住回调值驱动三栏/两栏/单栏切换。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';

const TAG: string = 'BreakpointTool';
const LOG_DOMAIN: number = 0x0012;
const BREAKPOINT_SM_MAX: number = 600;
const BREAKPOINT_MD_MAX: number = 840;

/** 断点值 */
export class Breakpoint {
  static readonly SM: string = 'sm';
  static readonly MD: string = 'md';
  static readonly LG: string = 'lg';
}

export type BreakpointObserver = (breakpoint: string) => void;

export class BreakpointTool {
  private static instance: BreakpointTool | null = null;

  private current: string = Breakpoint.SM;
  private attached: boolean = false;
  private observers: Array<BreakpointObserver> = [];

  private constructor() {
  }

  static getInstance(): BreakpointTool {
    if (BreakpointTool.instance === null) {
      BreakpointTool.instance = new BreakpointTool();
    }
    return BreakpointTool.instance;
  }

  /** 绑定主窗口（幂等；须在 UIAbility 主线程调用，EntryAbility.onWindowStageCreate） */
  attach(windowStage: window.WindowStage): void {
    if (this.attached) {
      return;
    }
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      this.applyWindowWidthPx(mainWindow.getWindowProperties().windowRect.width);
      mainWindow.on('windowSizeChange', (size: window.Size): void => {
        this.applyWindowWidthPx(size.width);
      });
      this.attached = true;
      hilog.info(LOG_DOMAIN, TAG, 'attached, breakpoint=%{public}s', this.current);
    } catch (err) {
      // attach 失败保持 sm 保守值（单栏可交互，不会白屏）
      hilog.warn(LOG_DOMAIN, TAG, 'attach failed: %{private}s', JSON.stringify(err));
    }
  }

  getBreakpoint(): string {
    return this.current;
  }

  /** 订阅断点变化（订阅即推送当前值；页面 aboutToDisappear 注销） */
  addObserver(observer: BreakpointObserver): void {
    if (!this.observers.includes(observer)) {
      this.observers.push(observer);
    }
    observer(this.current);
  }

  removeObserver(observer: BreakpointObserver): void {
    const index: number = this.observers.indexOf(observer);
    if (index >= 0) {
      this.observers.splice(index, 1);
    }
  }

  private applyWindowWidthPx(widthPx: number): void {
    if (!(widthPx > 0)) {
      return;
    }
    // 该方法同时被 windowSizeChange 回调调用：display 读取可能抛错，须自捕获防断链
    let density: number = 1;
    try {
      const pixelsPerVp: number = display.getDefaultDisplaySync().densityPixels;
      if (pixelsPerVp > 0) {
        density = pixelsPerVp;
      }
    } catch (err) {
      hilog.warn(LOG_DOMAIN, TAG, 'read display failed: %{private}s', JSON.stringify(err));
    }
    const widthVp: number = widthPx / density;
    let next: string = Breakpoint.LG;
    if (widthVp < BREAKPOINT_SM_MAX) {
      next = Breakpoint.SM;
    } else if (widthVp < BREAKPOINT_MD_MAX) {
      next = Breakpoint.MD;
    }
    if (next === this.current) {
      return;
    }
    this.current = next;
    hilog.info(LOG_DOMAIN, TAG, 'breakpoint -> %{public}s (width=%{public}d vp)', next, Math.round(widthVp));
    for (const observer of this.observers) {
      try {
        observer(next);
      } catch (err) {
        hilog.error(LOG_DOMAIN, TAG, 'observer error: %{private}s', JSON.stringify(err));
      }
    }
  }
}

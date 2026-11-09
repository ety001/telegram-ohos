/**
 * 全屏媒体覆盖层（M3-media）：ChatPanel bindContentCover 挂载。
 *
 * - PhotoPreview：图片全屏预览。ImageFit.Contain + PinchGesture 双指缩放（1~5x，简版：
 *   无平移/双击/惯性，复杂手势 M5）；点击背景或右上角关闭。
 * - VideoPlayCover：视频全屏播放。XComponent(SURFACE) 提供 surfaceId，VideoPlayerController
 *   驱动 AVPlayer（fd:// 沙盒文件）；控制条：关闭 / 播放暂停 / 时长。
 *   surface 就绪时序：XComponentController 子类 onSurfaceCreated(id) 官方推荐通道为主
 *   （官方文档明示 onLoad 早于 onSurfaceCreated，onLoad 期取 surfaceId 不可靠——复审修复），
 *   onLoad 取值 + 300ms 定时兜底保留为附加防御。
 */
import { VideoPlayerController, PlayerState } from '../core/VideoPlayerController';
import { MessageContent } from '../core/MessageContent';
import { ChatUi } from '../pages/ChatUi';

/**
 * XComponentController 子类：surface 创建完成的官方回调通道（API 12+）。
 * onLoad 触发时 surface 尚未创建（官方文档时序：onLoad → onSurfaceCreated），
 * 子类覆写 onSurfaceCreated(surfaceId) 才是可靠的 surfaceId 获取时机。
 */
class VideoSurfaceController extends XComponentController {
  /** surface 创建回调（宿主组件注入；置 null 即解绑） */
  onReady: ((surfaceId: string) => void) | null = null;

  onSurfaceCreated(surfaceId: string): void {
    if (this.onReady !== null) {
      this.onReady(surfaceId);
    }
  }
}

/** 预览图源（data URI 或应用沙盒 file URI，均直接喂 Image） */
@Component
export struct PhotoPreview {
  src: string = '';
  onClose: () => void = (): void => {
  };
  @State previewScale: number = 1;
  private baseScale: number = 1;

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // 图片层：等比完整显示 + pinch 缩放（简版：仅缩放不平移）
      Image(this.src)
        .objectFit(ImageFit.Contain)
        .width('100%')
        .height('100%')
        .scale({ x: this.previewScale, y: this.previewScale })
        .gesture(
          PinchGesture({ fingers: 2, distance: 3 })
            .onActionStart((): void => {
              this.baseScale = this.previewScale;
            })
            .onActionUpdate((event: GestureEvent): void => {
              const next: number = this.baseScale * event.scale;
              this.previewScale = Math.min(5, Math.max(1, next));
            })
            .onActionEnd((): void => {
              if (this.previewScale < 1.02) {
                this.previewScale = 1; // 近似回弹到 1x（避免残留 1.00x 附近微缩放）
              }
            })
        )
        .onClick((): void => {
          this.onClose();
        })

      Text('×')
        .fontSize(24)
        .fontColor('#FFFFFF')
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .borderRadius(20)
        .backgroundColor('#66000000')
        .margin({ top: 34, right: 16 })
        .onClick((): void => {
          this.onClose();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#E6000000')
  }
}

/** 视频播放覆盖层：XComponent 渲染 + AVPlayer 控制 */
@Component
export struct VideoPlayCover {
  path: string = '';
  title: string = '';
  onClose: () => void = (): void => {
  };
  @State playerState: string = PlayerState.IDLE;
  @State durationText: string = '';
  private controller: VideoPlayerController = new VideoPlayerController();
  private surfaceController: VideoSurfaceController = new VideoSurfaceController();
  private surfaceReady: boolean = false;
  private surfaceFallbackTimer: number = -1;

  aboutToAppear(): void {
    this.controller.setStateListener((state: string): void => {
      this.playerState = state;
      if (state === PlayerState.PLAYING || state === PlayerState.PAUSED) {
        const ms: number = this.controller.getDurationMs();
        this.durationText = ms > 0 ? MessageContent.formatDuration(Math.floor(ms / 1000)) : '';
      }
    });
    // 官方推荐通道：surface 创建完成回调（onLoad 期 surface 尚未创建，取值不可靠）
    this.surfaceController.onReady = (surfaceId: string): void => {
      this.onSurfaceReady(surfaceId);
    };
    this.controller.open(this.path);
    // surface 就绪附加防御：官方回调缺失时（API 差异）onLoad + 延迟轮询兜底
    this.surfaceFallbackTimer = setTimeout((): void => {
      this.tryBindSurface();
    }, 300);
  }

  aboutToDisappear(): void {
    this.surfaceController.onReady = null;
    if (this.surfaceFallbackTimer >= 0) {
      clearTimeout(this.surfaceFallbackTimer);
      this.surfaceFallbackTimer = -1;
    }
    this.controller.release();
  }

  /** 官方通道：XComponent surface 创建完成（surfaceId 由回调参数直给） */
  private onSurfaceReady(surfaceId: string): void {
    if (this.surfaceReady || surfaceId.length === 0) {
      return;
    }
    this.surfaceReady = true;
    this.controller.setSurface(surfaceId);
  }

  /** 兜底通道：onLoad/定时器经 getXComponentSurfaceId 主动查询 */
  private tryBindSurface(): void {
    if (this.surfaceReady) {
      return;
    }
    try {
      const surfaceId: string = this.surfaceController.getXComponentSurfaceId();
      if (surfaceId.length > 0) {
        this.surfaceReady = true;
        this.controller.setSurface(surfaceId);
      }
    } catch (err) {
      // surface 尚未创建：等待 onLoad 或下次兜底
    }
  }

  build() {
    Column() {
      // 顶栏：标题 + 关闭
      Row() {
        Text(this.title)
          .fontSize(15)
          .fontColor('#F5F5F5')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('×')
          .fontSize(24)
          .fontColor('#FFFFFF')
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .borderRadius(20)
          .backgroundColor('#66000000')
          .onClick((): void => {
            this.onClose();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      // 画面层：XComponent surface（AVPlayer 渲染目标）
      Stack({ alignContent: Alignment.Center }) {
        XComponent({ type: XComponentType.SURFACE, controller: this.surfaceController })
          .onLoad((): void => {
            this.tryBindSurface();
          })
          .width('100%')
          .height('100%')
          .onClick((): void => {
            this.controller.toggle();
          })

        if (this.playerState === PlayerState.PREPARING || this.playerState === PlayerState.IDLE) {
          Text('加载中…')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .opacity(0.85)
        } else if (this.playerState === PlayerState.ERROR) {
          Text('视频播放失败')
            .fontSize(14)
            .fontColor(ChatUi.BUBBLE_ERROR)
        } else if (this.playerState === PlayerState.PAUSED) {
          // 暂停提示（点击画面恢复）
          Text('已暂停 · 点击画面继续')
            .fontSize(13)
            .fontColor('#FFFFFF')
            .opacity(0.8)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(12)
            .backgroundColor('#66000000')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#000000')

      // 底部控制条：播放/暂停 + 状态/时长
      Row({ space: 10 }) {
        Text(this.playerState === PlayerState.PLAYING ? '❚❚' : '▶')
          .fontSize(15)
          .fontColor('#FFFFFF')
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .borderRadius(19)
          .backgroundColor(this.playerState === PlayerState.ERROR ? '#66333333' : ChatUi.ACCENT)
          .onClick((): void => {
            this.controller.toggle();
          })
        Text(this.statusText())
          .fontSize(13)
          .fontColor('#BFC9D4')
          .layoutWeight(1)
        Text('关闭')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(16)
          .backgroundColor('#33FFFFFF')
          .onClick((): void => {
            this.onClose();
          })
      }
      .width('100%')
      .height(58)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor('#CC0A0A0A')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }

  private statusText(): string {
    if (this.playerState === PlayerState.ERROR) {
      return '无法播放该格式';
    }
    if (this.playerState === PlayerState.COMPLETED) {
      return this.durationText.length > 0 ? `已播完 · ${this.durationText}` : '已播完';
    }
    if (this.playerState === PlayerState.PLAYING || this.playerState === PlayerState.PAUSED) {
      return this.durationText.length > 0 ? `时长 ${this.durationText}` : '播放中';
    }
    return '准备中…';
  }
}

/**
 * 全屏媒体查看器（M7-B1）：Swiper 多图横向滑动 + 每页 pinch 缩放 + 顶/底操作浮层。
 *
 * - ViewerPhoto：查看器条目（消息 id + 选中档 file id + minithumbnail 兜底）；
 * - 预载策略：当前页 PHOTO 优先级全图，邻页 ±1 预载（FileDownloadStore 全局状态复用）；
 * - 操作条：保存（已就绪走 MediaSaver，未就绪先 USER_ACTION 下载并提示）/ 删除（回调给
 *   ChatPanel 复用消息确认链）；转发跨 overlay 协调挂 B2 后（计划 §5B.1）。
 * 日志红线：不落图片路径/消息内容。
 */
import { ChatUi } from '../pages/ChatUi';
import { FileDownloadStore, DownloadPriority } from '../core/FileDownloadStore';
import { MediaSaver, SaveResult } from '../core/MediaSaver';
import { common } from '@kit.AbilityKit';
import { CloseIcon } from './Icons';

/** 查看器条目 */
export class ViewerPhoto {
  messageId: number = 0;
  fileId: number = 0;
  miniData: string = '';
  fileReady: boolean = false;
}

/** 单页可缩放图（pinch 1~5x，近 1x 回弹；沿 PhotoPreview 手势参数） */
@Component
struct ZoomablePage {
  page: ViewerPhoto = new ViewerPhoto();
  @State zoomScale: number = 1;
  @State src: string = '';
  private baseScale: number = 1;
  private readonly fileObserver: (fileId: number) => void = (fileId: number): void => {
    if (fileId === this.page.fileId && fileId !== 0) {
      this.refresh();
    }
  };

  aboutToAppear(): void {
    FileDownloadStore.getInstance().addObserver(this.fileObserver);
    this.refresh();
    this.preload();
  }

  aboutToDisappear(): void {
    FileDownloadStore.getInstance().removeObserver(this.fileObserver);
  }

  private refresh(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const ready: boolean = this.page.fileId !== 0 && store.isReady(this.page.fileId);
    this.src = ready ? store.getReadyUri(this.page.fileId) :
      (this.page.miniData.length > 0 ? `data:image/jpeg;base64,${this.page.miniData}` : '');
  }

  private preload(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.page.fileId;
    if (fileId !== 0 && !store.isReady(fileId) && !store.isFailed(fileId)) {
      store.downloadFile(fileId, DownloadPriority.PHOTO, 0, 0);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.src.length > 0) {
        Image(this.src)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
          .scale({ x: this.zoomScale, y: this.zoomScale })
          .gesture(
            PinchGesture({ fingers: 2, distance: 3 })
              .onActionStart((): void => {
                this.baseScale = this.zoomScale;
              })
              .onActionUpdate((event: GestureEvent): void => {
                this.zoomScale = Math.min(5, Math.max(1, this.baseScale * event.scale));
              })
              .onActionEnd((): void => {
                if (this.zoomScale < 1.02) {
                  this.zoomScale = 1;
                }
              })
          )
      } else {
        LoadingProgress()
          .width(36)
          .height(36)
          .color('#FFFFFF')
      }
    }
    .width('100%')
    .height('100%')
  }
}

@Component
export struct MediaViewer {
  /** 照片清单（调用方从会话当前窗口组装） */
  photos: Array<ViewerPhoto> = [];
  /** 初始定位下标 */
  startIndex: number = 0;
  onClose: () => void = (): void => {
  };
  /** 删除回调（ChatPanel 复用消息删除确认链） */
  onDelete: (messageId: number) => void = (messageId: number): void => {
  };

  @State index: number = 0;
  @State saveState: string = '';
  /** 各页就绪态（Swiper 当前页变化驱动预载；简化：进入时全部触发预载，当前页优先级更高） */
  private saveRequested: boolean = false;

  aboutToAppear(): void {
    this.index = this.startIndex;
    this.preloadAround(this.startIndex);
  }

  build() {
    Stack() {
      // 图片层：横向滑动
      Swiper(this.scroller) {
        ForEach(this.photos, (photo: ViewerPhoto) => {
          ZoomablePage({ page: photo })
        }, (photo: ViewerPhoto) => `${photo.messageId}_${photo.fileId}`)
      }
      .index(this.startIndex)
      .loop(false)
      .indicator(false)
      .cachedCount(1)
      .width('100%')
      .height('100%')
      .onChange((index: number): void => {
        this.index = index;
        this.preloadAround(index);
      })

      // 顶部浮层：关闭 + 计数
      Row({ space: 12 }) {
        CloseIcon({ iconSize: 16, iconColor: '#FFFFFF' })
          .width(40)
          .height(40)
          .onClick((): void => {
            this.onClose();
          })
        Blank()
        Text(this.saveState.length > 0 ? this.saveState : `${this.index + 1} / ${this.photos.length}`)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor('#66000000')
          .margin({ right: 16 })
      }
      .width('100%')
      .height(56)
      .padding({ left: 12, right: 8, top: 30 })
      .alignItems(VerticalAlign.Center)

      // 底部操作条：保存 / 删除
      Row({ space: 24 }) {
        this.actionButton('保存', (): void => {
          this.saveCurrent();
        })
        this.actionButton('删除', (): void => {
          if (this.index >= 0 && this.index < this.photos.length) {
            this.onDelete(this.photos[this.index].messageId);
          }
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .height(64)
      .alignItems(VerticalAlign.Center)
      .backgroundColor('#B3000000')
      .align(Alignment.Bottom)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#E6000000')
  }

  private scroller: SwiperController = new SwiperController();

  @Builder
  actionButton(title: string, action: () => void) {
    Text(title)
      .fontSize(14)
      .fontColor('#FFFFFF')
      .padding({ left: 18, right: 18, top: 8, bottom: 8 })
      .borderRadius(18)
      .backgroundColor('#40FFFFFF')
      .onClick((): void => {
        action();
      })
  }

  /** 邻页预载：当前页与邻页同 PHOTO 优先级（气泡预载同档，FileDownloadStore 幂等去重） */
  private preloadAround(index: number): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const ranges: Array<[number, number]> = [
      [index, DownloadPriority.PHOTO],
      [index - 1, DownloadPriority.PHOTO],
      [index + 1, DownloadPriority.PHOTO]
    ];
    for (const range of ranges) {
      const i: number = range[0];
      const priority: number = range[1];
      if (i < 0 || i >= this.photos.length) {
        continue;
      }
      const fileId: number = this.photos[i].fileId;
      if (fileId !== 0 && !store.isReady(fileId) && !store.isFailed(fileId)) {
        store.downloadFile(fileId, priority, 0, 0);
      }
    }
  }

  /** 保存当前图：未就绪先触发下载并提示；就绪走 MediaSaver（DocumentViewPicker 存图） */
  private saveCurrent(): void {
    if (this.index < 0 || this.index >= this.photos.length) {
      return;
    }
    const photo: ViewerPhoto = this.photos[this.index];
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (photo.fileId === 0 || !store.isReady(photo.fileId)) {
      if (photo.fileId !== 0 && !store.isActive(photo.fileId)) {
        store.downloadFile(photo.fileId, DownloadPriority.USER_ACTION, 0, 0);
      }
      this.saveState = '下载中…';
      return;
    }
    if (this.saveRequested) {
      return;
    }
    this.saveRequested = true;
    const hostContext: Object | undefined = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      this.saveRequested = false;
      return;
    }
    const context: common.UIAbilityContext = hostContext as common.UIAbilityContext;
    MediaSaver.saveDocument(context, store.getLocalPath(photo.fileId), `photo_${photo.messageId}.jpg`)
      .then((result: string): void => {
        this.saveRequested = false;
        if (result === SaveResult.SAVED) {
          this.saveState = '已保存';
        } else if (result !== SaveResult.CANCELLED) {
          this.saveState = '保存失败';
        }
        if (this.saveState.length > 0) {
          setTimeout((): void => {
            this.saveState = '';
          }, 2000);
        }
      })
      .catch((): void => {
        this.saveRequested = false;
        this.saveState = '保存失败';
      });
  }
}

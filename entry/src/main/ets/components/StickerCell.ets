/**
 * 贴纸格（M7-A2）：贴纸面板网格单元。
 * 渲染优先级：sticker.sticker（webp 直渲，下载完成 file URI）> thumbnail > emoji 占位灰底。
 * 下载：THUMBNAIL 优先级自动预载（组件挂载即拉，FileDownloadStore 全局状态复用）；
 * 观察者驱动就绪刷新（下载完成 → @State 置位 → Image 出现）。
 */
import { ChatUi } from '../pages/ChatUi';
import { FileDownloadStore, DownloadPriority } from '../core/FileDownloadStore';

@Component
export struct StickerCell {
  /** sticker 对象（stickerSetInfo.covers 首项或全量 sticker） */
  sticker: Record<string, Object> = { 'emoji': '·' } as Record<string, Object>;
  /** 单元尺寸（vp） */
  cellSize: number = 76;
  /** 圆形裁切（贴纸包封面用） */
  round: boolean = false;

  @State ready: boolean = false;
  @State thumbReady: boolean = false;

  private static readNumber(record: Record<string, Object>, field: string): number {
    const value: Object | undefined = record[field];
    return typeof value === 'number' && Number.isFinite(value) ? value : 0;
  }

  private static asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }

  private stickerFileId(): number {
    const file: Record<string, Object> | null = StickerCell.asRecord(this.sticker['sticker']);
    return file === null ? 0 : StickerCell.readNumber(file, 'id');
  }

  private thumbFileId(): number {
    const thumb: Record<string, Object> | null = StickerCell.asRecord(this.sticker['thumbnail']);
    if (thumb === null) {
      return 0;
    }
    const file: Record<string, Object> | null = StickerCell.asRecord(thumb['file']);
    return file === null ? 0 : StickerCell.readNumber(file, 'id');
  }

  private emoji(): string {
    const value: Object | undefined = this.sticker['emoji'];
    const emoji: string = typeof value === 'string' ? value : '';
    return emoji.length > 0 ? emoji : '·';
  }

  private readonly fileObserver: (fileId: number) => void = (fileId: number): void => {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (fileId === this.stickerFileId() && fileId !== 0) {
      this.ready = store.isReady(fileId);
    } else if (fileId === this.thumbFileId() && fileId !== 0) {
      this.thumbReady = store.isReady(fileId);
    }
  };

  aboutToAppear(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    store.addObserver(this.fileObserver);
    this.refresh();
    const fileId: number = this.stickerFileId();
    const thumbId: number = this.thumbFileId();
    if (fileId !== 0 && !store.isReady(fileId) && !store.isFailed(fileId)) {
      store.downloadFile(fileId, DownloadPriority.THUMBNAIL, 0, 0);
    }
    if (thumbId !== 0 && !store.isReady(thumbId) && !store.isFailed(thumbId)) {
      store.downloadFile(thumbId, DownloadPriority.THUMBNAIL, 0, 0);
    }
  }

  aboutToDisappear(): void {
    FileDownloadStore.getInstance().removeObserver(this.fileObserver);
  }

  private refresh(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.stickerFileId();
    const thumbId: number = this.thumbFileId();
    this.ready = fileId !== 0 && store.isReady(fileId);
    this.thumbReady = thumbId !== 0 && store.isReady(thumbId);
  }

  /** 当前展示源：本体（webp 可解码；tgs/webm 由 thumbnail 兜底）> 缩略图 > 空 */
  private src(): string {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.stickerFileId();
    if (fileId !== 0 && store.isReady(fileId)) {
      const uri: string = store.getReadyUri(fileId);
      if (uri.length > 0) {
        return uri;
      }
    }
    const thumbId: number = this.thumbFileId();
    if (thumbId !== 0 && store.isReady(thumbId)) {
      const uri: string = store.getReadyUri(thumbId);
      if (uri.length > 0) {
        return uri;
      }
    }
    return '';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.src().length > 0) {
        Image(this.src())
          .width(this.cellSize)
          .height(this.cellSize)
          .objectFit(ImageFit.Contain)
          .borderRadius(this.round ? this.cellSize / 2 : 0)
          .clip(this.round)
      } else {
        Text(this.emoji())
          .fontSize(this.cellSize * 0.4)
          .fontColor(ChatUi.TEXT_SECONDARY)
      }
    }
    .width(this.cellSize)
    .height(this.cellSize)
  }
}

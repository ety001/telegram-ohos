/**
 * 会话头像（M6-4）：三级渐进渲染。
 * 1. chatPhotoInfo.small 下载完成 → Image 真图（FileDownloadStore，THUMBNAIL 优先级）；
 * 2. minithumbnail（base64 JPEG data URI，随 chat 对象即到）先行灰度显示；
 * 3. 首字母色环占位（chatId hash 取色，既有视觉）。
 * 在线绿点（右下角）：私聊 userStatusOnline 时叠加（online prop 由行模型传入）。
 * 刷新：订阅 FileDownloadStore（头像文件就绪）。
 */
import { ChatUi } from '../pages/ChatUi';
import { FileDownloadStore, DownloadPriority } from '../core/FileDownloadStore';

/** 在线绿点色（叠加在头像右下角描边圆） */
const ONLINE_DOT_COLOR: string = '#7BC862';

@Component
export struct ChatAvatar {
  chatId: number = 0;
  title: string = '';
  /** 头像小图 file id（0 = 无头像，直接走占位链） */
  avatarFileId: number = 0;
  /** minithumbnail 裸 base64（空串跳过） */
  avatarMini: string = '';
  /** 私聊在线（叠加绿点） */
  online: boolean = false;
  avatarSize: number = 46;

  @State ready: boolean = false;
  @State imageSrc: string = '';

  private readonly fileObserver: (fileId: number) => void = (fileId: number): void => {
    if (fileId === this.avatarFileId && fileId !== 0) {
      this.refresh();
    }
  };

  aboutToAppear(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    store.addObserver(this.fileObserver);
    this.refresh();
    // 自动预载头像小图（低优先；失败静默——占位链兜底）
    if (this.avatarFileId !== 0 && !store.isReady(this.avatarFileId) && !store.isFailed(this.avatarFileId)) {
      store.downloadFile(this.avatarFileId, DownloadPriority.THUMBNAIL, 0, 0);
    }
  }

  aboutToDisappear(): void {
    FileDownloadStore.getInstance().removeObserver(this.fileObserver);
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack() {
        Circle({ width: this.avatarSize, height: this.avatarSize })
          .fill(ChatUi.avatarColor(this.chatId))
        if (this.imageSrc.length > 0) {
          Image(this.imageSrc)
            .width(this.avatarSize)
            .height(this.avatarSize)
            .borderRadius(this.avatarSize / 2)
            .clip(true)
        } else {
          Text(ChatUi.avatarLetter(this.title))
            .fontSize(this.avatarSize * 0.42)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
      }
      .width(this.avatarSize)
      .height(this.avatarSize)

      if (this.online) {
        // 绿点：底色描边圈 + 实心圆（右下角）
        Stack({ alignContent: Alignment.Center }) {
          Circle({ width: 14, height: 14 })
            .fill(ChatUi.LIST_BG)
          Circle({ width: 10, height: 10 })
            .fill(ONLINE_DOT_COLOR)
        }
        .width(14)
        .height(14)
        .markAnchor({ x: '50%', y: '50%' })
      }
    }
    .width(this.avatarSize)
    .height(this.avatarSize)
  }

  /** 当前展示源：真图（file:// 沙盒 URI）> minithumbnail data URI > 空（占位字母） */
  private refresh(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const fileId: number = this.avatarFileId;
    this.ready = fileId !== 0 && store.isReady(fileId);
    if (this.ready) {
      this.imageSrc = store.getReadyUri(fileId);
      return;
    }
    this.imageSrc = this.avatarMini.length > 0 ? `data:image/jpeg;base64,${this.avatarMini}` : '';
  }
}

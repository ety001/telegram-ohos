/**
 * 共享媒体区（M7-B2）：按会话浏览照片/视频/文件/链接（searchChatMessages 过滤器分页）。
 *
 * - tabs：照片（3 列网格）/ 视频（行）/ 文件（行）/ 链接（行）；
 * - 分页：foundChatMessages.next_from_message_id 游标 + onReachEnd 续拉（from_message_id 游标）；
 * - 照片点击 → MediaViewer（本 tab 清单内滑动定位，复用 M7-B1）；
 * - 视频点击 → 未就绪触发下载（完成后自动拉起 VideoPlayCover，观察者链）；
 * - 文件点击 → 下载完成后 MediaSaver 保存；链接点击 → openLink。
 * 日志红线：不落消息内容/文件名（仅 tab 与数量）。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ChatUi } from './ChatUi';
import { ChatListStore } from '../core/ChatListStore';
import { MessageContent, PhotoInfo, VideoInfo, DocumentInfo } from '../core/MessageContent';
import { FileDownloadStore, DownloadPriority } from '../core/FileDownloadStore';
import { MediaSaver, SaveResult } from '../core/MediaSaver';
import { MediaViewer, ViewerPhoto } from '../components/MediaViewer';
import { VideoPlayCover } from '../components/MediaOverlays';
import { StickerCell } from '../components/StickerCell';
import { BackIcon } from '../components/Icons';
import { TdClient } from '../tdlib/TdClient';
import { MessageStore } from '../core/MessageStore';
import { promptAction } from '@kit.ArkUI';
import { TdUpdateRouter } from '../core/TdUpdateRouter';
import { TdReq, TdField, TdType } from '../core/TdConstants';

const PAGE_LIMIT: number = 50;
const LOAD_TIMEOUT_MS: number = 20000;

/** 单 tab 分页状态 */
class TabState {
  messages: Array<Record<string, Object>> = [];
  nextFromId: number = 0;
  hasMore: boolean = true;
  loading: boolean = false;
  loaded: boolean = false;
}

@Component
struct PhotoGridCell {
  message: Record<string, Object> = {};
  onOpen: (messageId: number) => void = (messageId: number): void => {
  };
  @State ready: boolean = false;
  @State src: string = '';
  private fileId: number = 0;
  private mini: string = '';
  private readonly fileObserver: (fileId: number) => void = (fileId: number): void => {
    if (fileId === this.fileId && fileId !== 0) {
      this.refresh();
    }
  };

  aboutToAppear(): void {
    const content: Record<string, Object> | null = this.asRecord(this.message[TdField.CONTENT]);
    const photo: PhotoInfo | null = content === null ? null : MessageContent.extractPhoto(content);
    if (photo === null) {
      return;
    }
    if (photo.selected !== null) {
      this.fileId = photo.selected.fileId;
    }
    this.mini = photo.miniData;
    FileDownloadStore.getInstance().addObserver(this.fileObserver);
    this.refresh();
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (this.fileId !== 0 && !store.isReady(this.fileId) && !store.isFailed(this.fileId)) {
      store.downloadFile(this.fileId, DownloadPriority.THUMBNAIL, 0, 0);
    }
  }

  aboutToDisappear(): void {
    FileDownloadStore.getInstance().removeObserver(this.fileObserver);
  }

  private refresh(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    const ready: boolean = this.fileId !== 0 && store.isReady(this.fileId);
    this.ready = ready;
    this.src = ready ? store.getReadyUri(this.fileId) :
      (this.mini.length > 0 ? `data:image/jpeg;base64,${this.mini}` : '');
  }

  private asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.src.length > 0) {
        Image(this.src)
          .width('100%')
          .aspectRatio(1)
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%')
          .aspectRatio(1)
          .backgroundColor(ChatUi.SEARCH_BG)
      }
    }
    .onClick((): void => {
      this.onOpen(this.asNumber(this.message[TdField.ID]));
    })
  }

  private asNumber(value: Object | undefined): number {
    return typeof value === 'number' && Number.isFinite(value) ? value : 0;
  }
}

@Component
struct VideoRow {
  message: Record<string, Object> = {};
  onPlay: (localPath: string) => void = (localPath: string): void => {
  };
  @State stateText: string = '点击下载播放';
  private fileId: number = 0;
  private fileName: string = '';
  private requested: boolean = false;
  private readonly fileObserver: (fileId: number) => void = (fileId: number): void => {
    if (fileId === this.fileId && fileId !== 0) {
      this.onFileChanged();
    }
  };

  aboutToAppear(): void {
    const content: Record<string, Object> | null = this.asRecord(this.message[TdField.CONTENT]);
    const video: VideoInfo | null = content === null ? null : MessageContent.extractVideo(content);
    if (video === null) {
      return;
    }
    this.fileId = video.videoFile !== null && typeof video.videoFile['id'] === 'number' ?
      video.videoFile['id'] as number : 0;
    this.fileName = video.fileName;
    FileDownloadStore.getInstance().addObserver(this.fileObserver);
    this.refreshState();
  }

  aboutToDisappear(): void {
    FileDownloadStore.getInstance().removeObserver(this.fileObserver);
  }

  private refreshState(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (this.fileId === 0) {
      this.stateText = '不可用';
    } else if (store.isReady(this.fileId)) {
      this.stateText = '点击播放';
    } else if (store.isActive(this.fileId)) {
      this.stateText = `下载中 ${store.getProgress(this.fileId) >= 0 ? Math.round(store.getProgress(this.fileId)) + '%' : '…'}`;
    } else if (store.isFailed(this.fileId)) {
      this.stateText = '下载失败 · 点击重试';
    } else {
      this.stateText = '点击下载播放';
    }
  }

  private onFileChanged(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    this.refreshState();
    if (store.isReady(this.fileId) && this.requested) {
      this.requested = false;
      this.onPlay(store.getLocalPath(this.fileId));
    }
  }

  private handleClick(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (this.fileId === 0) {
      return;
    }
    if (store.isReady(this.fileId)) {
      this.onPlay(store.getLocalPath(this.fileId));
      return;
    }
    if (!store.isActive(this.fileId) || store.isFailed(this.fileId)) {
      store.downloadFile(this.fileId, DownloadPriority.USER_ACTION, 0, 0);
    }
    this.requested = true;
  }

  private asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }

  build() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(this.fileName.length > 0 ? this.fileName : '视频')
          .fontSize(14)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.stateText)
          .fontSize(12)
          .fontColor(ChatUi.TEXT_SECONDARY)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      PlayMark()
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.handleClick();
    })
  }
}

@Component
struct DocumentRow {
  message: Record<string, Object> = {};
  @State stateText: string = '点击下载保存';
  private fileId: number = 0;
  private fileName: string = '';
  private readonly fileObserver: (fileId: number) => void = (fileId: number): void => {
    if (fileId === this.fileId && fileId !== 0) {
      this.refreshState();
    }
  };

  aboutToAppear(): void {
    const content: Record<string, Object> | null = this.asRecord(this.message[TdField.CONTENT]);
    const doc: DocumentInfo | null = content === null ? null : MessageContent.extractDocument(content);
    if (doc === null) {
      return;
    }
    this.fileId = doc.fileId;
    this.fileName = doc.fileName;
    FileDownloadStore.getInstance().addObserver(this.fileObserver);
    this.refreshState();
  }

  aboutToDisappear(): void {
    FileDownloadStore.getInstance().removeObserver(this.fileObserver);
  }

  private refreshState(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (this.fileId === 0) {
      this.stateText = '不可用';
    } else if (store.isReady(this.fileId)) {
      this.stateText = '点击保存';
    } else if (store.isActive(this.fileId)) {
      this.stateText = '下载中…';
    } else if (store.isFailed(this.fileId)) {
      this.stateText = '下载失败 · 点击重试';
    } else {
      this.stateText = '点击下载保存';
    }
  }

  private saving: boolean = false;

  private handleClick(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (this.fileId === 0) {
      return;
    }
    if (!store.isReady(this.fileId)) {
      if (!store.isActive(this.fileId) || store.isFailed(this.fileId)) {
        store.downloadFile(this.fileId, DownloadPriority.USER_ACTION, 0, 0);
      }
      return;
    }
    if (this.saving) {
      return; // 存储框防重（PR28 审计 P2-2）
    }
    this.saving = true;
    const hostContext: Object | undefined = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      return;
    }
    const context: common.UIAbilityContext = hostContext as common.UIAbilityContext;
    MediaSaver.saveDocument(context, store.getLocalPath(this.fileId),
      this.fileName.length > 0 ? this.fileName : `file_${this.fileId}`)
      .catch((): void => {
      })
      .finally((): void => {
        this.saving = false;
      });
  }

  private asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }

  build() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(this.fileName.length > 0 ? this.fileName : '文件')
          .fontSize(14)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.stateText)
          .fontSize(12)
          .fontColor(ChatUi.TEXT_SECONDARY)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      DocMark()
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.handleClick();
    })
  }
}

/** 行尾自绘播放标记（小圆 + 三角） */
@Component
struct PlayMark {
  build() {
    Stack({ alignContent: Alignment.Center }) {
      Circle({ width: 30, height: 30 })
        .fill(ChatUi.SEARCH_BG)
      Path()
        .width(12)
        .height(12)
        .commands('M3 2 L10 6 L3 10 Z')
        .fill(ChatUi.TEXT_PRIMARY)
    }
    .width(30)
    .height(30)
  }
}

/** 行尾自绘文件标记（圆角方块 + 横线） */
@Component
struct DocMark {
  build() {
    Stack() {
      Column({ space: 3 }) {
        Rect().width(14).height(2).radius(1).fill(ChatUi.TEXT_SECONDARY)
        Rect().width(10).height(2).radius(1).fill(ChatUi.TEXT_SECONDARY)
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width(30)
    .height(30)
    .borderRadius(8)
    .backgroundColor(ChatUi.SEARCH_BG)
  }
}

@Entry
@Component
struct MediaPage {
  @State chatId: number = 0;
  @State chatTitle: string = '';
  @State activeTab: string = 'photo';
  @State photoTab: TabState = new TabState();
  @State videoTab: TabState = new TabState();
  @State docTab: TabState = new TabState();
  @State urlTab: TabState = new TabState();
  // 页内覆盖层：查看器 / 视频播放（单 bindContentCover 分流）
  @State overlayKind: string = '';
  @State viewerPhotos: Array<ViewerPhoto> = [];
  @State viewerStart: number = 0;
  @State videoPath: string = '';
  private actionSeq: number = 0;

  aboutToAppear(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params !== undefined && params !== null) {
      const idObj: Object | undefined = params['chatId'];
      if (typeof idObj === 'number') {
        this.chatId = idObj;
      }
    }
    this.chatTitle = ChatListStoreSafe.title(this.chatId);
    this.loadTab();
  }

  build() {
    Column() {
      // 顶栏：返回 + 标题
      Row({ space: 12 }) {
        BackIcon({ iconSize: 20, iconColor: ChatUi.TEXT_PRIMARY })
          .width(32)
          .height(32)
          .onClick((): void => {
            router.back();
          })
        Text(`媒体 · ${this.chatTitle}`)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .height(54)
      .padding({ left: 14, right: 16 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(ChatUi.LIST_BG)

      // tabs
      Row({ space: 4 }) {
        this.tabButton('照片', 'photo')
        this.tabButton('视频', 'video')
        this.tabButton('文件', 'doc')
        this.tabButton('链接', 'url')
      }
      .width('100%')
      .height(44)
      .padding({ left: 8, right: 8 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(ChatUi.LIST_BG)

      // 内容
      if (this.activeTab === 'photo') {
        this.photoGrid()
      } else if (this.activeTab === 'video') {
        this.messageList(this.videoTab, 'video')
      } else if (this.activeTab === 'doc') {
        this.messageList(this.docTab, 'doc')
      } else {
        this.messageList(this.urlTab, 'url')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ChatUi.CHAT_BG)
    // 页内覆盖层
    .bindContentCover(this.overlayKind !== '', this.overlayBuilder(), {
      modalTransition: ModalTransition.DEFAULT,
      enableSafeArea: true,
      onWillDismiss: (action: DismissContentCoverAction): void => {
        this.overlayKind = '';
        action.dismiss();
      }
    })
  }

  @Builder
  tabButton(title: string, kind: string) {
    Text(title)
      .fontSize(14)
      .fontWeight(this.activeTab === kind ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.activeTab === kind ? ChatUi.TEXT_PRIMARY : ChatUi.TEXT_SECONDARY)
      .height(32)
      .padding({ left: 12, right: 12 })
      .borderRadius(16)
      .backgroundColor(this.activeTab === kind ? ChatUi.SEARCH_BG : Color.Transparent)
      .onClick((): void => {
        if (this.activeTab !== kind) {
          this.activeTab = kind;
          this.loadTab();
        }
      })
  }

  @Builder
  photoGrid() {
    if (this.photoTab.messages.length === 0 && !this.photoTab.loading) {
      this.emptyHint(this.photoTab.hasMore)
    } else {
      Grid() {
        ForEach(this.photoTab.messages, (message: Record<string, Object>) => {
          GridItem() {
            PhotoGridCell({
              message: message,
              onOpen: (messageId: number): void => {
                this.openViewer(messageId);
              }
            })
          }
        }, (message: Record<string, Object>) => `${this.asNumber(message[TdField.ID])}`)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .cachedCount(6)
      .onReachEnd((): void => {
        this.loadMore();
      })
    }
  }

  @Builder
  messageList(state: TabState, kind: string) {
    if (state.messages.length === 0 && !state.loading) {
      this.emptyHint(state.hasMore)
    } else {
      List() {
        ForEach(state.messages, (message: Record<string, Object>) => {
          ListItem() {
            if (kind === 'video') {
              VideoRow({
                message: message,
                onPlay: (localPath: string): void => {
                  this.videoPath = localPath;
                  this.overlayKind = 'video';
                }
              })
            } else if (kind === 'doc') {
              DocumentRow({ message: message })
            } else {
              this.urlRow(message)
            }
          }
        }, (message: Record<string, Object>) => `${this.asNumber(message[TdField.ID])}_${kind}`)
        ListItem() {
          Row() {
            if (state.loading) {
              LoadingProgress().width(20).height(20).color(ChatUi.ACCENT)
              Text('加载中…').fontSize(12).fontColor(ChatUi.TEXT_SECONDARY).margin({ left: 8 })
            } else if (!state.hasMore) {
              Text(state.messages.length > 0 ? '没有更多了' : '').fontSize(12).fontColor(ChatUi.TEXT_SECONDARY)
            }
          }
          .width('100%')
          .height(40)
          .justifyContent(FlexAlign.Center)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .onReachEnd((): void => {
        this.loadMore();
      })
    }
  }

  @Builder
  urlRow(message: Record<string, Object>) {
    Column({ space: 2 }) {
      Text(MessageContent.previewTextOf(message))
        .fontSize(14)
        .fontColor(ChatUi.LINK_IN)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .onClick((): void => {
      this.openUrl(message);
    })
  }

  @Builder
  emptyHint(hasMore: boolean) {
    Column() {
      Text(hasMore ? '加载中…' : '暂无内容')
        .fontSize(13)
        .fontColor(ChatUi.TEXT_SECONDARY)
        .opacity(0.7)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  overlayBuilder() {
    if (this.overlayKind === 'viewer') {
      MediaViewer({
        photos: this.viewerPhotos,
        startIndex: this.viewerStart,
        onClose: (): void => {
          this.overlayKind = '';
        },
        onDelete: (messageId: number): void => {
          // 先收查看器再弹删除方式选择（沿 ChatPanel 三选 ActionMenu 语义）
          this.overlayKind = '';
          this.confirmRemove(messageId);
        }
      })
    } else if (this.overlayKind === 'video') {
      VideoPlayCover({
        path: this.videoPath,
        title: this.chatTitle,
        onClose: (): void => {
          this.overlayKind = '';
        }
      })
    }
  }

  // ---------------- 数据 ----------------

  private currentTab(): TabState {
    if (this.activeTab === 'photo') {
      return this.photoTab;
    }
    if (this.activeTab === 'video') {
      return this.videoTab;
    }
    if (this.activeTab === 'doc') {
      return this.docTab;
    }
    return this.urlTab;
  }

  private filterOf(): Record<string, Object> {
    let type: string = TdType.FILTER_PHOTO;
    if (this.activeTab === 'video') {
      type = TdType.FILTER_VIDEO;
    } else if (this.activeTab === 'doc') {
      type = TdType.FILTER_DOCUMENT;
    } else if (this.activeTab === 'url') {
      type = TdType.FILTER_URL;
    }
    return { ['@type']: type };
  }

  /** 当前 tab 拉取（首屏；幂等防重入） */
  private loadTab(): void {
    const state: TabState = this.currentTab();
    if (state.loaded || state.loading) {
      return;
    }
    this.requestPage(state, 0);
  }

  /** 续拉（游标 next_from_message_id） */
  private loadMore(): void {
    const state: TabState = this.currentTab();
    if (state.loading || !state.hasMore) {
      return;
    }
    this.requestPage(state, state.nextFromId);
  }

  private requestPage(state: TabState, fromMessageId: number): void {
    if (this.chatId === 0 || state.loading) {
      return;
    }
    state.loading = true;
    this.actionSeq += 1;
    const extra: string = `media_${this.actionSeq}`;
    TdUpdateRouter.getInstance().waitForExtra(extra, LOAD_TIMEOUT_MS)
      .then((update: Record<string, Object>): void => {
        state.loading = false;
        const typeObj: Object | undefined = update['@type'];
        if (typeObj !== TdType.FOUND_CHAT_MESSAGES) {
          state.hasMore = false;
          return;
        }
        const listObj: Object | undefined = update['messages'];
        const list: Array<Object> = Array.isArray(listObj) ? listObj as Array<Object> : [];
        let added: number = 0;
        const fresh: Array<Record<string, Object>> = new Array<Record<string, Object>>();
        for (const item of list) {
          if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
            fresh.push(item as Record<string, Object>);
            added += 1;
          }
        }
        // @State 一级观察：内嵌数组必须整组重赋值才可观测（PR28 审计 P1-1）
        state.messages = state.messages.concat(fresh);
        const nextObj: Object | undefined = update[TdField.NEXT_FROM_MESSAGE_ID];
        const next: number = typeof nextObj === 'number' ? nextObj : 0;
        state.nextFromId = next;
        state.loaded = true;
        if (next === 0 || (fromMessageId !== 0 && added === 0)) {
          state.hasMore = false;
        }
      })
      .catch((reason: string): void => {
        state.loading = false;
        state.hasMore = false;
      });
    const request: Record<string, Object> = {
      ['@type']: TdReq.SEARCH_CHAT_MESSAGES,
      'chat_id': this.chatId,
      'query': '',
      'from_message_id': fromMessageId,
      'offset': 0,
      'limit': PAGE_LIMIT,
      'filter': this.filterOf()
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  /** 照片点击 → 组装本 tab 清单打开查看器 */
  private openViewer(messageId: number): void {
    const photos: Array<ViewerPhoto> = new Array<ViewerPhoto>();
    let start: number = 0;
    for (const message of this.photoTab.messages) {
      const content: Record<string, Object> | null = this.asRecord(message[TdField.CONTENT]);
      const photo: PhotoInfo | null = content === null ? null : MessageContent.extractPhoto(content);
      if (photo === null) {
        continue;
      }
      const item: ViewerPhoto = new ViewerPhoto();
      const idObj: Object | undefined = message[TdField.ID];
      item.messageId = typeof idObj === 'number' ? idObj : 0;
      item.fileId = photo.selected !== null ? photo.selected.fileId : 0;
      item.miniData = photo.miniData;
      if (item.messageId === messageId) {
        start = photos.length;
      }
      photos.push(item);
    }
    if (photos.length === 0) {
      return;
    }
    this.viewerPhotos = photos;
    this.viewerStart = start;
    this.overlayKind = 'viewer';
  }

  private openUrl(message: Record<string, Object>): void {
    const content: Record<string, Object> | null = this.asRecord(message[TdField.CONTENT]);
    if (content === null) {
      return;
    }
    const formatted: Record<string, Object> | null = this.asRecord(content[TdField.TEXT]);
    const textObj: Object | undefined = formatted === null ? undefined : formatted[TdField.TEXT];
    const text: string = typeof textObj === 'string' ? textObj : '';
    if (text.startsWith('http://') || text.startsWith('https://')) {
      const hostContext: Object | undefined = this.getUIContext().getHostContext();
      if (hostContext === undefined) {
        return;
      }
      const context: common.UIAbilityContext = hostContext as common.UIAbilityContext;
      context.openLink(text).catch((): void => {
      });
    }
  }

  /** 删除确认（ActionMenu 三选，沿 ChatPanel 语义）：乐观本地移除 + revoke 请求 */
  private confirmRemove(messageId: number): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: '删除消息？',
      buttons: [
        { text: '删除（所有人）', color: ChatUi.BUBBLE_ERROR },
        { text: '删除（仅自己）', color: ChatUi.TEXT_PRIMARY },
        { text: '取消', color: ChatUi.TEXT_SECONDARY }
      ]
    }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (result.index !== 0 && result.index !== 1) {
        return;
      }
      this.removeLocalById(messageId);
      MessageStore.getInstance().deleteMessages(this.chatId, [messageId], result.index === 0);
    }).catch((): void => {
    });
  }

  /** 媒体页删除：本地清单移除（乐观） */
  private removeLocalById(messageId: number): void {
    const state: TabState = this.currentTab();
    const kept: Array<Record<string, Object>> = new Array<Record<string, Object>>();
    for (const message of state.messages) {
      const idObj: Object | undefined = message[TdField.ID];
      const id: number = typeof idObj === 'number' ? idObj : 0;
      if (id !== messageId) {
        kept.push(message);
      }
    }
    state.messages = kept;
  }

  private asNumber(value: Object | undefined): number {
    return typeof value === 'number' && Number.isFinite(value) ? value : 0;
  }

  private asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }
}

/** 标题读取壳（避免 @Entry 组件内多 store 混排） */
class ChatListStoreSafe {
  static title(chatId: number): string {
    return ChatListStore.getInstance().getTitle(chatId);
  }
}


/**
 * 资料页（M7-G）：会话资料浏览——大头像（chatPhotoInfo.big）/ 标题 / 状态行 /
 * @username（user.usernames.active_usernames）/ 简介（getUserFullInfo.bio）/
 * 共同群组数（userFullInfo.group_in_common_count）/ 手机号（user.phone_number，有则显）/
 * 媒体·文件·链接入口（跳 MediaPage，M7-B2）。
 *
 * 入口：ChatPage/Index 顶栏标题点击（原 MediaPage 入口让位至此，媒体经本页二级进入）。
 * 数据：getUser（UserStore 已有）+ getUserFullInfo（一次性 @extra 查询）。
 * 日志红线：资料内容不落日志。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ChatUi } from './ChatUi';
import { ChatListStore } from '../core/ChatListStore';
import { UserStore } from '../core/UserStore';
import { StickerCell } from '../components/StickerCell';
import { BackIcon } from '../components/Icons';
import { FileDownloadStore, DownloadPriority } from '../core/FileDownloadStore';
import { TdClient } from '../tdlib/TdClient';
import { TdUpdateRouter } from '../core/TdUpdateRouter';
import { TdReq, TdField, TdType } from '../core/TdConstants';

@Component
struct ProfileAvatar {
  chatId: number = 0;
  title: string = '';
  bigFileId: number = 0;
  smallFileId: number = 0;
  mini: string = '';
  avatarSize: number = 96;

  @State readyBig: boolean = false;
  @State readySmall: boolean = false;
  private readonly fileObserver: (fileId: number) => void = (fileId: number): void => {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (fileId === this.bigFileId && fileId !== 0) {
      this.readyBig = store.isReady(fileId);
    } else if (fileId === this.smallFileId && fileId !== 0) {
      this.readySmall = store.isReady(fileId);
    }
  };

  aboutToAppear(): void {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    store.addObserver(this.fileObserver);
    this.readyBig = this.bigFileId !== 0 && store.isReady(this.bigFileId);
    this.readySmall = this.smallFileId !== 0 && store.isReady(this.smallFileId);
    if (this.bigFileId !== 0 && !store.isReady(this.bigFileId) && !store.isFailed(this.bigFileId)) {
      store.downloadFile(this.bigFileId, DownloadPriority.PHOTO, 0, 0);
    }
    if (this.smallFileId !== 0 && !store.isReady(this.smallFileId) && !store.isFailed(this.smallFileId)) {
      store.downloadFile(this.smallFileId, DownloadPriority.THUMBNAIL, 0, 0);
    }
  }

  aboutToDisappear(): void {
    FileDownloadStore.getInstance().removeObserver(this.fileObserver);
  }

  private src(): string {
    const store: FileDownloadStore = FileDownloadStore.getInstance();
    if (this.readyBig) {
      const uri: string = store.getReadyUri(this.bigFileId);
      if (uri.length > 0) {
        return uri;
      }
    }
    if (this.readySmall) {
      const uri: string = store.getReadyUri(this.smallFileId);
      if (uri.length > 0) {
        return uri;
      }
    }
    return this.mini.length > 0 ? `data:image/jpeg;base64,${this.mini}` : '';
  }

  build() {
    Stack() {
      Circle({ width: this.avatarSize, height: this.avatarSize })
        .fill(ChatUi.avatarColor(this.chatId))
      if (this.src().length > 0) {
        Image(this.src())
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
  }
}

@Entry
@Component
struct ProfilePage {
  @State chatId: number = 0;
  @State chatTitle: string = '';
  @State statusLine: string = '';
  @State username: string = '';
  @State bio: string = '';
  @State phone: string = '';
  @State commonGroups: number = -1; // -1 = 未拉到
  @State bigFileId: number = 0;
  @State smallFileId: number = 0;
  @State avatarMini: string = '';
  private readonly userObserver: () => void = (): void => {
    this.refreshUserRows();
  };

  aboutToAppear(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params !== undefined && params !== null) {
      const idObj: Object | undefined = params['chatId'];
      if (typeof idObj === 'number') {
        this.chatId = idObj;
      }
    }
    this.chatTitle = ChatListStore.getInstance().getTitle(this.chatId);
    this.bigFileId = ChatListStore.getInstance().getAvatarBigFileId(this.chatId);
    this.smallFileId = ChatListStore.getInstance().getAvatarFileId(this.chatId);
    this.avatarMini = ChatListStore.getInstance().getAvatarMini(this.chatId);
    const userId: number = ChatListStore.getInstance().privateUserIdOf(this.chatId);
    if (userId !== 0) {
      UserStore.getInstance().ensureUser(userId);
    }
    this.refreshUserRows();
    UserStore.getInstance().addObserver(this.userObserver);
    this.queryFullInfo(userId);
  }

  aboutToDisappear(): void {
    UserStore.getInstance().removeObserver(this.userObserver);
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 12 }) {
        BackIcon({ iconSize: 20, iconColor: ChatUi.TEXT_PRIMARY })
          .width(32)
          .height(32)
          .onClick((): void => {
            router.back();
          })
        Text('资料')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .layoutWeight(1)
      }
      .width('100%')
      .height(54)
      .padding({ left: 14, right: 16 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(ChatUi.LIST_BG)

      Scroll() {
        Column({ space: 12 }) {
          // 头像 + 标题 + 状态
          Column({ space: 6 }) {
            ProfileAvatar({
              chatId: this.chatId,
              title: this.chatTitle,
              bigFileId: this.bigFileId,
              smallFileId: this.smallFileId,
              mini: this.avatarMini,
              avatarSize: 96
            })
            Text(this.chatTitle)
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor(ChatUi.TEXT_PRIMARY)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
            if (this.statusLine.length > 0) {
              Text(this.statusLine)
                .fontSize(13)
                .fontColor(this.statusLine === '在线' ? ChatUi.ONLINE_FG : ChatUi.STATUS_FG)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 16, bottom: 8 })

          // 信息行（有内容才渲染）
          Column() {
            if (this.username.length > 0) {
              this.infoRow('用户名', `@${this.username}`, true)
            }
            if (this.bio.length > 0) {
              this.infoRow('简介', this.bio, false)
            }
            if (this.phone.length > 0) {
              this.infoRow('手机', this.phone, true)
            }
            if (this.commonGroups >= 0) {
              this.infoRow('共同群组', `${this.commonGroups}`, false)
            }
          }
          .width('100%')
          .borderRadius(12)
          .backgroundColor(ChatUi.LIST_BG)

          // 媒体入口（跳 M7-B2 共享媒体区）
          Row() {
            Text('媒体、文件和链接')
              .fontSize(15)
              .fontColor(ChatUi.TEXT_PRIMARY)
              .layoutWeight(1)
            Text('>')
              .fontSize(16)
              .fontColor(ChatUi.TEXT_SECONDARY)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .borderRadius(12)
          .backgroundColor(ChatUi.LIST_BG)
          .onClick((): void => {
            router.pushUrl({
              url: 'pages/MediaPage',
              params: { 'chatId': this.chatId } as Record<string, Object>
            }).catch((): void => {
            });
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ChatUi.CHAT_BG)
  }

  @Builder
  infoRow(label: string, value: string, copyable: boolean) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(12)
        .fontColor(ChatUi.TEXT_SECONDARY)
      Text(value)
        .fontSize(14)
        .fontColor(ChatUi.TEXT_PRIMARY)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .onClick((): void => {
      if (!copyable) {
        return;
      }
      this.copyText(value);
    })
  }

  private copyText(text: string): void {
    const hostContext: Object | undefined = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      return;
    }
    const context: common.UIAbilityContext = hostContext as common.UIAbilityContext;
    try {
      context.startAbility({
        action: 'ohos.want.action.copyData',
        parameters: { 'content': text } as Record<string, Object>
      }).catch((): void => {
      });
    } catch (err) {
      // 剪贴板能力不可用：静默
    }
  }

  /** 用户行刷新：昵称/用户名/手机/状态（UserStore 缓存） */
  private refreshUserRows(): void {
    const userId: number = ChatListStore.getInstance().privateUserIdOf(this.chatId);
    if (userId === 0) {
      return;
    }
    this.username = UserStore.getInstance().usernameOf(userId);
    this.phone = UserStore.getInstance().phoneOf(userId);
    const status: string | null = UserStore.getInstance().statusText(userId);
    this.statusLine = status === null ? '' : status;
  }

  private fullInfoSeq: number = 0;

  /** getUserFullInfo 一次性查询（bio/共同群数；仅私聊） */
  private queryFullInfo(userId: number): void {
    if (userId === 0) {
      return;
    }
    // extra 序号化（PR31 审计 P1-2 同源：固定 extra 并发等待 duplicate reject）
    this.fullInfoSeq += 1;
    const extra: string = `userFullInfoQuery_${this.fullInfoSeq}`;
    TdUpdateRouter.getInstance().waitForExtra(extra, 10000)
      .then((update: Record<string, Object>): void => {
        const typeObj: Object | undefined = update['@type'];
        if (typeObj !== 'userFullInfo') {
          return;
        }
        const bioFormatted: Record<string, Object> | null =
          this.asRecord(update[TdField.BIO]);
        if (bioFormatted !== null) {
          const textObj: Object | undefined = bioFormatted[TdField.TEXT];
          this.bio = typeof textObj === 'string' ? textObj : '';
        }
        this.commonGroups = this.asNumber(update[TdField.GROUP_IN_COMMON_COUNT], -1);
      })
      .catch((reason: string): void => {
        // 超时静默（bio/共同群不显示）
      });
    const request: Record<string, Object> = {
      ['@type']: TdReq.GET_USER_FULL_INFO,
      'user_id': userId
    };
    request[TdField.EXTRA] = extra;
    TdClient.getInstance().send(request);
  }

  private asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }

  private asNumber(value: Object | undefined, fallback: number): number {
    return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
  }
}

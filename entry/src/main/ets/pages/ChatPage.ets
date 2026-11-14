/**
 * 聊天页（sm 断点单栏栈）：会话列表点击推入；只保留顶栏（返回 + 会话名）与参数传递，
 * 消息流与输入区内嵌 ChatPanel（M3 组件化，与 md/lg Index 聊天区复用同一组件）。
 *
 * 顶部栏标题实时跟随 ChatListStore 的 updateChatTitle。
 *
 * 安全区策略：应用未开 setWindowLayoutFullScreen 全屏布局，
 * 系统默认避让状态栏/手势条（页根组件不主动延伸），无需手工 padding——策略验证挂真机（M2 验收项）。
 */
import { router } from '@kit.ArkUI';
import { ChatListStore, ChatListObserver } from '../core/ChatListStore';
import { UserStore } from '../core/UserStore';
import { ChatPanel } from '../components/ChatPanel';
import { ChatUi } from './ChatUi';
import { BackIcon, SearchIcon } from '../components/Icons';

@Entry
@Component
struct ChatPage {
  @State chatId: number = 0;
  @State chatTitle: string = '';
  /** 会话内搜索开关（M6-5，@Link 传入 ChatPanel） */
  @State showSearch: boolean = false;
  /** 顶栏状态行（UI 打磨：私聊 在线/最后见于…，官方 historyStatusFg 语义） */
  @State statusLine: string = '';
  /** 输入面板开关（M7-A1，@Link 传入 ChatPanel） */
  @State panelKind: string = '';
  private readonly userObserver: () => void = (): void => {
    this.refreshStatus();
  };
  private readonly storeObserver: ChatListObserver = (): void => {
    this.refreshTitle();
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
    this.refreshTitle();
    this.refreshStatus();
    ChatListStore.getInstance().addObserver(this.storeObserver);
    UserStore.getInstance().addObserver(this.userObserver);
  }

  aboutToDisappear(): void {
    ChatListStore.getInstance().removeObserver(this.storeObserver);
    UserStore.getInstance().removeObserver(this.userObserver);
  }

  private refreshTitle(): void {
    if (this.chatId === 0) {
      return;
    }
    const title: string = ChatListStore.getInstance().getTitle(this.chatId);
    this.chatTitle = title.length > 0 ? title : '会话';
  }

  /** 状态行：仅私聊显示（在线/最后见于…）；群聊/频道不显示 */
  private refreshStatus(): void {
    const userId: number = ChatListStore.getInstance().privateUserIdOf(this.chatId);
    if (userId === 0) {
      this.statusLine = '';
      return;
    }
    const text: string | null = UserStore.getInstance().statusText(userId);
    this.statusLine = text === null ? '' : text;
  }

  build() {
    Column() {
      // 顶部栏：返回 + 会话名 + 搜索入口（M6-5）
      Row({ space: 12 }) {
        BackIcon({ iconSize: 20, iconColor: ChatUi.TEXT_PRIMARY })
          .width(32)
          .height(32)
          .onClick((): void => {
            router.back();
          })
        Column({ space: 1 }) {
          Text(this.chatTitle)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(ChatUi.TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick((): void => {
              router.pushUrl({ url: 'pages/MediaPage', params: { 'chatId': this.chatId } as Record<string, Object> }).catch((): void => {
              });
            })
          if (this.statusLine.length > 0) {
            Text(this.statusLine)
              .fontSize(12)
              .fontColor(this.statusLine === '在线' ? ChatUi.ONLINE_FG : ChatUi.STATUS_FG)
              .maxLines(1)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SearchIcon({ iconSize: 18, iconColor: ChatUi.TEXT_PRIMARY })
          .width(32)
          .height(32)
          .onClick((): void => {
            this.showSearch = !this.showSearch;
          })
      }
      .width('100%')
      .height(54)
      .padding({ left: 14, right: 16 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(ChatUi.LIST_BG)

      // 消息流 + 输入区：ChatPanel 内嵌（生命周期/已读上报由组件自理）
      if (this.chatId !== 0) {
        ChatPanel({ chatId: this.chatId, showSearch: $showSearch, panelKind: $panelKind })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ChatUi.CHAT_BG)
  }
}

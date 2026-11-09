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
import { ChatPanel } from '../components/ChatPanel';
import { ChatUi } from './ChatUi';

@Entry
@Component
struct ChatPage {
  @State chatId: number = 0;
  @State chatTitle: string = '';
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
    ChatListStore.getInstance().addObserver(this.storeObserver);
  }

  aboutToDisappear(): void {
    ChatListStore.getInstance().removeObserver(this.storeObserver);
  }

  private refreshTitle(): void {
    if (this.chatId === 0) {
      return;
    }
    const title: string = ChatListStore.getInstance().getTitle(this.chatId);
    this.chatTitle = title.length > 0 ? title : '会话';
  }

  build() {
    Column() {
      // 顶部栏：返回 + 会话名
      Row({ space: 12 }) {
        Text('<')
          .fontSize(24)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            router.back();
          })
        Text(this.chatTitle)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .height(52)
      .padding({ left: 14, right: 16 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(ChatUi.LIST_BG)

      // 消息流 + 输入区：ChatPanel 内嵌（生命周期/已读上报由组件自理）
      if (this.chatId !== 0) {
        ChatPanel({ chatId: this.chatId })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ChatUi.CHAT_BG)
  }
}

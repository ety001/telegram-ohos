/**
 * 聊天页占位（M2）：sm 断点从会话列表推入；消息流/输入区 M3 接入。
 *
 * 顶部栏展示 chat title（实时跟随 ChatListStore 的 updateChatTitle），
 * 消息区与输入区为占位（输入禁用）。
 *
 * 安全区策略：应用未开 setWindowLayoutFullScreen 全屏布局，
 * 系统默认避让状态栏/手势条（页根组件不主动延伸），无需手工 padding——策略验证挂真机（M2 验收项）。
 */
import { router } from '@kit.ArkUI';
import { ChatListStore, ChatListObserver } from '../core/ChatListStore';
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

      // 消息区占位（M3：getChatHistory + 按天分组渲染）
      Column({ space: 10 }) {
        Text('消息流 M3 接入')
          .fontSize(14)
          .fontColor(ChatUi.TEXT_SECONDARY)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(ChatUi.CHAT_BG)

      // 输入区占位（M3：RichEditor + 发送）
      Row() {
        TextInput({ placeholder: '输入消息（M3 接入）' })
          .layoutWeight(1)
          .height(40)
          .backgroundColor(ChatUi.INPUT_BG)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .placeholderColor(ChatUi.TEXT_SECONDARY)
          .enabled(false)
      }
      .width('100%')
      .height(60)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(ChatUi.LIST_BG)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ChatUi.CHAT_BG)
  }
}

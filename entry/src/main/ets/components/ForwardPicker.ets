/**
 * 转发目标选择器（M6-3）：bindContentCover 全屏覆盖层。
 *
 * 数据：ChatListStore 有序会话 + 标题本地过滤（简版，复用列表既有视觉）。
 * 交互：点击行 = 选定目标 → onPick(chatId) 回调（ChatPanel 执行 forwardMessages）→ 关闭。
 * 头部：关闭按钮 + 标题 + 搜索框。
 */
import { ChatListStore } from '../core/ChatListStore';
import { ChatUi, ChatRowModel } from '../pages/ChatUi';

@Component
export struct ForwardPicker {
  /** 选中目标回调（ChatPanel：forwardMessages 后关闭覆盖层） */
  onPick: (chatId: number) => void = (chatId: number): void => {
  };
  onClose: () => void = (): void => {
  };

  @State keyword: string = '';
  @State rows: Array<ChatRowModel> = [];

  aboutToAppear(): void {
    this.rebuild();
  }

  build() {
    Column() {
      // 头部：关闭 + 标题 + 搜索框
      Row({ space: 10 }) {
        Text('✕')
          .fontSize(16)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.onClose();
          })
        Text('转发到...')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      TextInput({ text: this.keyword, placeholder: '搜索会话' })
        .height(38)
        .borderRadius(19)
        .backgroundColor(ChatUi.SEARCH_BG)
        .fontColor(ChatUi.TEXT_PRIMARY)
        .fontSize(14)
        .placeholderColor(ChatUi.TEXT_SECONDARY)
        .padding({ left: 14, right: 14 })
        .margin({ left: 12, right: 12, bottom: 8 })
        .onChange((value: string): void => {
          this.keyword = value;
          this.rebuild();
        })

      if (this.rows.length === 0) {
        Column() {
          Text('未找到匹配会话')
            .fontSize(13)
            .fontColor(ChatUi.TEXT_SECONDARY)
            .opacity(0.7)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.rows, (row: ChatRowModel) => {
            ListItem() {
              Row({ space: 12 }) {
                Stack() {
                  Circle({ width: 36, height: 36 })
                    .fill(ChatUi.avatarColor(row.chatId))
                  Text(ChatUi.avatarLetter(row.title))
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                }
                .width(36)
                .height(36)
                Text(row.title)
                  .fontSize(15)
                  .fontColor(ChatUi.TEXT_PRIMARY)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .height(52)
              .padding({ left: 14, right: 14 })
              .alignItems(VerticalAlign.Center)
              .onClick((): void => {
                this.onPick(row.chatId);
              })
            }
          }, (row: ChatRowModel) => `${row.chatId}_${row.title}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .cachedCount(10)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ChatUi.LIST_BG)
  }

  /** 关键字过滤快照（标题 contains；与主列表一致的简版口径） */
  private rebuild(): void {
    const store: ChatListStore = ChatListStore.getInstance();
    const rows: Array<ChatRowModel> = new Array<ChatRowModel>();
    const keyword: string = this.keyword.trim().toLowerCase();
    for (const chatId of store.getOrderedIds()) {
      if (keyword.length > 0 && store.getTitle(chatId).toLowerCase().indexOf(keyword) < 0) {
        continue;
      }
      rows.push(ChatUi.buildRow(store.getChat(chatId) as Record<string, Object>));
    }
    this.rows = rows;
  }
}

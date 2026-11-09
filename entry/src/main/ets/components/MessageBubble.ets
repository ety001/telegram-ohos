/**
 * 消息气泡（M3）：ChatPanel 消息流子组件。
 *
 * - outgoing 靠右蓝底 / incoming 靠左深灰底（PLAN §4 MessageBubble）
 * - 文本渲染 formattedText.text 纯文本版（entities 富文本 M5）
 * - 状态角标：发送中时钟（自绘表盘，避免 emoji/资源依赖）/ 失败红色感叹号（点击重试）/
 *   已送出单勾 / 对方已读双勾（updateChatReadOutbox 游标判定）
 */
import { ChatUi } from '../pages/ChatUi';

/** 气泡视图模型：由 TDLib message 对象按需投影（ChatPanel 构建） */
export class MessageBubbleModel {
  messageId: number = 0;
  isOutgoing: boolean = false;
  text: string = '';
  timeText: string = '';
  /** 发送时间（unix 秒，分组头计算用） */
  dateSeconds: number = 0;
  /** sending / failed / sent（sent = 已送出服务器；isRead 另计） */
  sendState: string = 'none';
  isRead: boolean = false;
  /** 失败原因（TDLib error.message 或本地超时文案，气泡下方小字透传） */
  errorText: string = '';
  canRetry: boolean = false;
  /** 分组头 day key（由 ChatPanel 生成分组头，气泡内不渲染） */
  dayKey: number = 0;

  /** ForEach 键后缀：状态/已读/内容指纹任一变化即换键，强制重建气泡（编辑与发送状态机可见刷新） */
  keySuffix(): string {
    // 文本全量入键（M3 复审 MEDIUM 修复：同长度编辑如改错别字时 length 不变会漏刷新）
    return `${this.messageId}_${this.sendState}_${this.isRead}_${this.text}_${this.errorText}`;
  }
}

/** 发送态枚举值（避免散落字符串） */
export class BubbleSendState {
  static readonly NONE: string = 'none';
  static readonly SENDING: string = 'sending';
  static readonly FAILED: string = 'failed';
  static readonly SENT: string = 'sent';
}

@Component
export struct MessageBubble {
  /** 组件入参（非 private：private 成员无法经组件构造器初始化） */
  model: MessageBubbleModel = new MessageBubbleModel();
  /** 失败气泡点击重试回调（ChatPanel 注入，调 MessageStore.retrySend） */
  onRetry: (messageId: number) => void = (messageId: number): void => {
  };

  build() {
    Row({ space: 8 }) {
      if (this.model.isOutgoing) {
        Blank()
          .layoutWeight(1)
      }
      Column() {
        if (this.model.text.length > 0) {
          Text(this.model.text)
            .fontSize(15)
            .lineHeight(21)
            .fontColor(this.model.isOutgoing ? '#FFFFFF' : ChatUi.TEXT_PRIMARY)
            .textAlign(TextAlign.Start)
        } else {
          // 非文本内容（图片/文件等 M3-media 接入前的占位）
          Text('[暂不支持的消息类型]')
            .fontSize(13)
            .fontColor(this.model.isOutgoing ? '#DCE9F7' : ChatUi.TEXT_SECONDARY)
        }
        Row({ space: 4 }) {
          if (this.model.sendState === BubbleSendState.FAILED) {
            Text(this.model.errorText.length > 0 ? this.model.errorText : '发送失败')
              .fontSize(10)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '60%' })
              .fontColor(ChatUi.BUBBLE_ERROR)
          }
          Text(this.model.timeText)
            .fontSize(10)
            .fontColor(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
          this.stateMark()
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Center)
        .margin({ top: 2 })
      }
      .constraintSize({ maxWidth: '78%' })
      .padding({ left: 11, right: 11, top: 7, bottom: 7 })
      .borderRadius(12)
      .backgroundColor(this.model.isOutgoing ? ChatUi.BUBBLE_OUT : ChatUi.BUBBLE_IN)
      .onClick((): void => {
        // 失败气泡点击 = 重试（其余点击无动作；长按菜单 M5）
        if (this.model.sendState === BubbleSendState.FAILED && this.model.canRetry) {
          this.onRetry(this.model.messageId);
        }
      })

      if (!this.model.isOutgoing) {
        Blank()
          .layoutWeight(1)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 2, bottom: 2 })
  }

  /** 状态角标：时钟 / 红色感叹号 / 单勾 / 双勾 */
  @Builder
  stateMark() {
    if (this.model.sendState === BubbleSendState.SENDING) {
      // 发送中：自绘小时钟（圆盘 + 指针），不依赖 emoji/符号资源
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 11, height: 11 })
          .fill(Color.Transparent)
          .stroke(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
          .strokeWidth(1)
        Rect({ width: 1, height: 3.5 })
          .fill(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
          .offset({ x: 0, y: -2.2 })
        Rect({ width: 3, height: 1 })
          .fill(this.model.isOutgoing ? '#C9E1F8' : ChatUi.TEXT_SECONDARY)
          .offset({ x: 1.5, y: 0.5 })
      }
      .width(11)
      .height(11)
    } else if (this.model.sendState === BubbleSendState.FAILED) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 13, height: 13 })
          .fill(ChatUi.BUBBLE_ERROR)
        Text('!')
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
      .width(13)
      .height(13)
    } else if (this.model.sendState === BubbleSendState.SENT) {
      Text(this.model.isRead ? '✓✓' : '✓')
        .fontSize(11)
        // 已读双勾弱化为浅色（Telegram 语义：单勾=已送出，双勾=已读）
        .fontColor(this.model.isRead ? '#9AC3EC' : '#C9E1F8')
    }
  }
}

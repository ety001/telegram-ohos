/**
 * 聊天相关页面共享视觉常量与小工具（M2）：会话列表列 / 聊天页复用。
 * 与登录流程页 AuthUi 平行的暗色系配色（Telegram 风格深蓝）。
 */
import { ChatListStore } from '../core/ChatListStore';
import { TimeFormat } from '../core/TimeFormat';
import { TdField } from '../core/TdConstants';
import { MessageContent } from '../core/MessageContent';
import { DraftStore } from '../core/DraftStore';

/** 会话行视图模型：由 TDLib chat 对象按需投影（仅可见行构建，千级列表零全量构建开销） */
export class ChatRowModel {
  chatId: number = 0;
  title: string = '';
  preview: string = '';
  timeText: string = '';
  unreadText: string = '';
  pinned: boolean = false;
  /** 免打扰中（notification_settings.mute_for > 0；行标记 + 未读角标置灰 + 菜单文案用） */
  muted: boolean = false;
  /** 本地草稿文本（M6-1，DraftStore；非空时行预览显示红「草稿」前缀，优先级最高） */
  draftLocal: string = '';
  /** 云端草稿文本（M6-1，chat.draft_message；本地为空时显示灰「草稿」前缀） */
  draftCloud: string = '';
}

export class ChatUi {
  static readonly NAV_BG: string = '#0E1621';
  static readonly LIST_BG: string = '#17212B';
  static readonly CHAT_BG: string = '#0E1621';
  static readonly SEARCH_BG: string = '#242F3D';
  static readonly INPUT_BG: string = '#242F3D';
  static readonly ACCENT: string = '#3390EC';
  static readonly TEXT_PRIMARY: string = '#F5F5F5';
  static readonly TEXT_SECONDARY: string = '#7D8E9E';
  static readonly ROW_PRESSED_BG: string = '#202B36';
  static readonly BADGE_BG: string = '#3390EC';
  /** 本地草稿前缀色（Telegram 语义：未发送内容警示红） */
  static readonly DRAFT_LOCAL: string = '#E17076';
  /** 跳转高亮背景（M6-2/5：引用条/搜索结果跳转目标短暂强调） */
  static readonly HIGHLIGHT_BG: string = '#333390EC';
  // 消息气泡（M3）：incoming 深灰 / outgoing 沿用 ACCENT 蓝
  static readonly BUBBLE_IN: string = '#242F3D';
  static readonly BUBBLE_OUT: string = '#3390EC';
  static readonly BUBBLE_ERROR: string = '#FF6B6B';

  /** 头像占位色板（chatId hash 取色；暗色背景下的中亮度系） */
  static readonly AVATAR_COLORS: Array<string> = [
    '#E17076', '#7BC862', '#E5CA77', '#65AADD',
    '#A695E7', '#EE7AAE', '#6EC9CB', '#FAA774'
  ];

  /** 头像颜色：chatId 对色板长度取模（chatId 负值取绝对值，稳定可复现） */
  static avatarColor(chatId: number): string {
    const palette: Array<string> = ChatUi.AVATAR_COLORS;
    const positive: number = chatId < 0 ? -chatId : chatId;
    return palette[positive % palette.length];
  }

  /** 头像首字母：标题首个码点（含 CJK/emoji 取整字），空标题回退 # */
  static avatarLetter(title: string): string {
    if (title.length === 0) {
      return '#';
    }
    const codePoint: number | undefined = title.codePointAt(0);
    if (codePoint === undefined) {
      return '#';
    }
    return String.fromCodePoint(codePoint).toUpperCase();
  }

  /** TDLib chat 对象 → 会话行视图模型（原对象不变更，纯投影） */
  static buildRow(chat: Record<string, Object>): ChatRowModel {
    const row: ChatRowModel = new ChatRowModel();
    const idObj: Object | undefined = chat[TdField.ID];
    if (typeof idObj === 'number') {
      row.chatId = idObj;
    }
    const titleObj: Object | undefined = chat[TdField.TITLE];
    if (typeof titleObj === 'string') {
      row.title = titleObj;
    }
    const lastMessage: Record<string, Object> | null = ChatUi.asRecord(chat[TdField.LAST_MESSAGE]);
    if (lastMessage !== null) {
      row.preview = ChatUi.previewText(lastMessage);
      const dateObj: Object | undefined = lastMessage[TdField.DATE];
      if (typeof dateObj === 'number') {
        row.timeText = TimeFormat.formatChatListTime(dateObj, Date.now());
      }
    }
    const unreadObj: Object | undefined = chat[TdField.UNREAD_COUNT];
    if (typeof unreadObj === 'number' && unreadObj > 0) {
      row.unreadText = unreadObj > 99 ? '99+' : `${unreadObj}`;
    }
    row.pinned = ChatListStore.getInstance().isPinned(row.chatId);
    row.muted = ChatListStore.getInstance().isMuted(row.chatId);
    // 草稿（M6-1）：本地草稿优先（红前缀），其次云端草稿（灰前缀）；均无走 last_message 预览
    row.draftLocal = DraftStore.getInstance().draftOf(row.chatId);
    if (row.draftLocal.length === 0) {
      row.draftCloud = ChatUi.cloudDraftText(chat);
    }
    return row;
  }

  /**
   * 云端草稿文本提取（M6-1）：chat.draft_message.input_message_text.text——
   * 1.8.63 draftMessage 字段名即 input_message_text（类型 InputMessageContent，纯文本草稿
   * 恒为 inputMessageText{text:formattedText{text}}）；draft_message 可为 null。
   */
  private static cloudDraftText(chat: Record<string, Object>): string {
    const draft: Record<string, Object> | null = ChatUi.asRecord(chat[TdField.DRAFT_MESSAGE]);
    if (draft === null) {
      return '';
    }
    const inputContent: Record<string, Object> | null = ChatUi.asRecord(draft[TdField.DRAFT_INPUT_CONTENT]);
    if (inputContent === null) {
      return '';
    }
    const formatted: Record<string, Object> | null = ChatUi.asRecord(inputContent[TdField.TEXT]);
    if (formatted === null) {
      return '';
    }
    const text: Object | undefined = formatted[TdField.TEXT];
    return typeof text === 'string' ? text : '';
  }

  /**
   * 最后消息预览：委托 MessageContent.previewTextOf（M3-notifications 起与会话列表/通知共用一份提取，
   * 文本压单行 + 媒体占位文案，见 core/MessageContent）。
   */
  private static previewText(lastMessage: Record<string, Object>): string {
    return MessageContent.previewTextOf(lastMessage);
  }

  private static asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }
}

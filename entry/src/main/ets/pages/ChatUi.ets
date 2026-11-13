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
  // ---------------- 头像与在线（M6-4） ----------------
  /** 头像小图 file id（0 = 无头像） */
  avatarFileId: number = 0;
  /** 头像 minithumbnail 裸 base64 */
  avatarMini: string = '';
  /** 私聊在线（绿点） */
  online: boolean = false;
}

export class ChatUi {
  // ---------------- 配色（对齐 tdesktop v7.4.3 官方 Night palette，规格见
  // tmp/tdesktop-theme-spec.md；键名注释即官方 palette 键） ----------------
  static readonly NAV_BG: string = '#17212B'; // windowBg
  static readonly LIST_BG: string = '#17212B'; // windowBg
  static readonly CHAT_BG: string = '#000E16'; // Night 壁纸实色（1×1 background.png）
  static readonly SEARCH_BG: string = '#232E3C'; // windowBgOver
  static readonly INPUT_BG: string = '#17212B'; // historyComposeAreaBg（平贴，非浮卡）
  static readonly ACCENT: string = '#5288C1'; // windowBgActive（发送图标/主按钮）
  static readonly TEXT_PRIMARY: string = '#F5F5F5'; // windowFg
  static readonly TEXT_SECONDARY: string = '#708499'; // windowSubTextFg
  static readonly ROW_PRESSED_BG: string = '#24303D'; // windowBgRipple
  static readonly BADGE_BG: string = '#4082BC'; // 未读角标（dialogs palette）
  static readonly BADGE_MUTED_BG: string = '#3E546A'; // 静音未读角标
  /** 本地草稿前缀色（Telegram 语义：未发送内容警示红） */
  static readonly DRAFT_LOCAL: string = '#E17076';
  /** 跳转高亮背景（M6-2/5：引用条/搜索结果跳转目标短暂强调） */
  static readonly HIGHLIGHT_BG: string = '#332E70A5'; // msgOutBgSelected 33%
  // 消息气泡（msgInBg/msgOutBg，Night palette:256/258）
  static readonly BUBBLE_IN: string = '#182533';
  static readonly BUBBLE_OUT: string = '#2B5278';
  static readonly BUBBLE_ERROR: string = '#EF5959'; // windowTextFgError
  // 气泡内时间文字（msgInDateFg/msgOutDateFg palette:270/272）
  static readonly DATE_TEXT_IN: string = '#6D7F8F';
  static readonly DATE_TEXT_OUT: string = '#7DA8D3';
  // service 文本（转发标签等，msgInServiceFg/msgOutServiceFg palette:262/264）
  static readonly SERVICE_TEXT_IN: string = '#71BAFA';
  static readonly SERVICE_TEXT_OUT: string = '#90CAFF';
  // 链接色（historyLinkInFg/OutFg palette:193/195）
  static readonly LINK_IN: string = '#70BAF5';
  static readonly LINK_OUT: string = '#83CAFF';
  // 在线状态文字/绿点（windowActiveTextFg #6ab3f3 语义；绿点沿用系统绿系）
  static readonly ONLINE_FG: string = '#6AB3F3';
  static readonly ONLINE_DOT: string = '#85DE85'; // peer2 NameFg 绿

  /**
   * 群聊发送者昵称色板（historyPeer1..8NameFg，Night palette:218-239；
   * 着色算法 = bareId % 7 → map{0,7,4,1,6,3,5} → palette 1..8，chat_style.cpp:1496-1505）
   */
  static readonly PEER_NAME_COLORS: Array<string> = [
    '#FB6169', '#85DE85', '#F3BC5C', '#65BDF3',
    '#B48BF2', '#FF5694', '#62D4E3', '#FAA357'
  ];
  /** 头像底色板（historyPeer1..8UserpicBg，palette:220-241；与昵称同 index 规则） */
  static readonly AVATAR_COLORS: Array<string> = [
    '#FF845E', '#9AD164', '#E5CA77', '#5CAFFA',
    '#B694F9', '#FF8AAC', '#5BCBE3', '#FEBB5B'
  ];

  /** 官方着色算法：id % 7 → map{0,7,4,1,6,3,5} → 色板 0..7（tdesktop DecideColorIndex） */
  private static readonly COLOR_INDEX_MAP: Array<number> = [0, 7, 4, 1, 6, 3, 5];

  static peerColorIndex(id: number): number {
    const bare: number = id < 0 ? -id : id;
    const colorIndex: number = bare % 7;
    return ChatUi.COLOR_INDEX_MAP[colorIndex];
  }

  /** 群聊发送者昵称色（官方 NameFg 色板 + DecideColorIndex 规则） */
  static peerNameColor(id: number): string {
    return ChatUi.PEER_NAME_COLORS[ChatUi.peerColorIndex(id)];
  }

  /** 头像颜色：chatId/userId 按 id%7 官方映射取色板（负值取绝对值，稳定可复现） */
  static avatarColor(chatId: number): string {
    return ChatUi.AVATAR_COLORS[ChatUi.peerColorIndex(chatId)];
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
    // 头像与在线（M6-4）
    row.avatarFileId = ChatListStore.getInstance().getAvatarFileId(row.chatId);
    row.avatarMini = ChatListStore.getInstance().getAvatarMini(row.chatId);
    row.online = ChatListStore.getInstance().isOnline(row.chatId);
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

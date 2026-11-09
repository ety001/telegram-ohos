/**
 * 聊天相关页面共享视觉常量与小工具（M2）：会话列表列 / 聊天页复用。
 * 与登录流程页 AuthUi 平行的暗色系配色（Telegram 风格深蓝）。
 */
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
}

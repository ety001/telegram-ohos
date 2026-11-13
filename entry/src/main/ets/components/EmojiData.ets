/**
 * emoji 精选数据源（M7-A1）：内置常用 unicode emoji 分类集。
 * v1 为静态精选（每分类 32 枚），不做 TDLib emoji 建议与自定义 emoji（登记后续）。
 */

export class EmojiCategory {
  title: string = '';
  emojis: Array<string> = [];
}

export class EmojiData {
  /** 分类标签（面板 tab 行） */
  static readonly CATEGORIES: Array<EmojiCategory> = EmojiData.build();

  private static build(): Array<EmojiCategory> {
    const list: Array<EmojiCategory> = new Array<EmojiCategory>();
    list.push(EmojiData.cat('笑脸', [
      '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂',
      '🙂', '🙃', '😉', '😊', '😇', '🥰', '😍', '🤩',
      '😘', '😗', '😚', '😙', '🥲', '😋', '😛', '😜',
      '🤪', '😝', '🤑', '🤗', '🤭', '🤫', '🤔', '🤐'
    ]));
    list.push(EmojiData.cat('手势', [
      '👍', '👎', '👌', '🤌', '✌️', '🤞', '🤟', '🤘',
      '🤙', '👈', '👉', '👆', '👇', '☝️', '👋', '🤚',
      '🖐️', '✋', '🖖', '👏', '🙌', '🤲', '🤝', '🙏',
      '💪', '🦾', '✍️', '🤳', '💅', '🤲', '👐', '🤛'
    ]));
    list.push(EmojiData.cat('动物', [
      '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼',
      '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🙈',
      '🙉', '🙊', '🐔', '🐧', '🐦', '🦆', '🦉', '🦇',
      '🐺', '🐗', '🐴', '🦄', '🐝', '🪲', '🦋', '🐌'
    ]));
    list.push(EmojiData.cat('食物', [
      '🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇',
      '🍓', '🫐', '🍈', '🍒', '🍑', '🥭', '🍍', '🥥',
      '🥝', '🍅', '🍆', '🥑', '🥦', '🌶️', '🌽', '🥕',
      '🍞', '🥐', '🥖', '🧀', '🥚', '🍳', '🥞', '🥓'
    ]));
    list.push(EmojiData.cat('活动', [
      '⚽', '🏀', '🏈', '⚾', '🥎', '🎾', '🏐', '🏉',
      '🥏', '🎱', '🪀', '🏓', '🏸', '🥊', '🥋', '⛳',
      '⛸️', '🎣', '🤿', '🎽', '🎿', '🛷', '🥌', '🎯',
      '🪁', '🎮', '🕹️', '🎲', '🧩', '🎰', '🎳', '🎮'
    ]));
    list.push(EmojiData.cat('物品', [
      '⌚', '📱', '💻', '⌨️', '🖥️', '🖨️', '🖱️', '💡',
      '🔦', '🕯️', '🧯', '🛢️', '💸', '💵', '💰', '🧾',
      '✉️', '📩', '📦', '📮', '🔧', '🔨', '🛠️', '⚙️',
      '🧲', '🔫', '💊', '🩹', '🩺', '🚪', '🪑', '🛏️'
    ]));
    list.push(EmojiData.cat('符号', [
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍',
      '💔', '❣️', '💕', '💞', '💓', '💗', '💖', '💘',
      '💯', '💢', '💥', '💫', '💦', '💨', '🎉', '🎊',
      '✨', '⚡', '🔥', '🌟', '⭐', '🌠', '☀️', '🌙'
    ]));
    return list;
  }

  private static cat(title: string, emojis: Array<string>): EmojiCategory {
    const c: EmojiCategory = new EmojiCategory();
    c.title = title;
    c.emojis = emojis;
    return c;
  }
}

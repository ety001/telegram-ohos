/**
 * 输入面板（M7-A）：挂在输入区上方的可展开面板（表情/贴纸/GIF 三 tab）。
 *
 * A1 范围：骨架 + 表情 tab（精选 unicode 集分类网格，点击经 onEmojiPick 回调插入输入框）；
 * 贴纸/GIF tab 占位（A2/A3 批次启用，禁用态文案）。官方交互语义：
 * - 开关按钮在输入框右端，输入空显示笑脸、非空切换发送钮（ChatPanel 负责）；
 * - 面板高度 ~300vp，展开时收起键盘。
 */
import { ChatUi } from '../pages/ChatUi';
import { EmojiData, EmojiCategory } from './EmojiData';
import { StickerStore } from '../core/StickerStore';
import { FileDownloadStore, DownloadPriority } from '../core/FileDownloadStore';
import { CloseIcon } from './Icons';
import { StickerCell } from './StickerCell';

/** 面板 tab 标识（'' = 关闭） */
export class PanelKind {
  static readonly NONE: string = '';
  static readonly EMOJI: string = 'emoji';
  static readonly STICKER: string = 'sticker';
  static readonly GIF: string = 'gif';
}

const PANEL_HEIGHT: number = 300;

@Component
export struct InputPanel {
  /** 当前面板类型（由 ChatPanel @Link 传入控制显隐） */
  @Link panelKind: string;
  /** emoji 选中回调（ChatPanel：插入输入框） */
  onEmojiPick: (emoji: string) => void = (emoji: string): void => {
  };
  /** 面板关闭回调（✕ / 再点笑脸） */
  onClose: () => void = (): void => {
  };
  /** 贴纸选中回调（ChatPanel：sendSticker） */
  onStickerPick: (sticker: Record<string, Object>) => void = (sticker: Record<string, Object>): void => {
  };
  /** GIF 选中回调（ChatPanel：sendAnimation） */
  onGifPick: (sticker: Record<string, Object>) => void = (sticker: Record<string, Object>): void => {
  };

  @State activeCategory: number = 0;
  @State activeTab: string = PanelKind.EMOJI;

  build() {
    Column() {
      // tab 行：表情 / 贴纸 / GIF（贴纸/GIF 为 A2/A3 占位禁用）
      Row({ space: 4 }) {
        this.tabButton('表情', PanelKind.EMOJI, true)
        this.tabButton('贴纸', PanelKind.STICKER, true)
        this.tabButton('GIF', PanelKind.GIF, true)
        Blank()
        CloseIcon({ iconSize: 14, iconColor: ChatUi.TEXT_SECONDARY })
          .width(32)
          .height(32)
          .onClick((): void => {
            this.onClose();
          })
      }
      .width('100%')
      .height(40)
      .padding({ left: 8, right: 8 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(ChatUi.SEARCH_BG)
        .margin({ left: 8, right: 8 })

      // 内容区
      if (this.activeTab === PanelKind.EMOJI) {
        this.emojiGrid()
      } else if (this.activeTab === PanelKind.STICKER) {
        this.stickerPanel()
      } else {
        this.gifPanel()
      }
    }
    .width('100%')
    .height(PANEL_HEIGHT)
    .backgroundColor(ChatUi.LIST_BG)
  }

  @Builder
  tabButton(title: string, kind: string, enabled: boolean) {
    Text(title)
      .fontSize(14)
      .fontWeight(this.activeTab === kind ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(!enabled ? ChatUi.TEXT_SECONDARY :
        (this.activeTab === kind ? ChatUi.TEXT_PRIMARY : ChatUi.TEXT_SECONDARY))
      .opacity(enabled ? 1 : 0.45)
      .height(32)
      .padding({ left: 12, right: 12 })
      .borderRadius(16)
      .backgroundColor(this.activeTab === kind ? ChatUi.SEARCH_BG : Color.Transparent)
      .onClick((): void => {
        if (enabled) {
          this.activeTab = kind;
        }
      })
  }

  /** emoji 分类 tab + 网格 */
  @Builder
  emojiGrid() {
    Column() {
      // 分类行
      Row({ space: 4 }) {
        ForEach(EmojiData.CATEGORIES, (cat: EmojiCategory, index: number) => {
          Text(cat.title)
            .fontSize(12)
            .fontWeight(this.activeCategory === index ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.activeCategory === index ? ChatUi.TEXT_PRIMARY : ChatUi.TEXT_SECONDARY)
            .height(28)
            .padding({ left: 10, right: 10 })
            .borderRadius(14)
            .backgroundColor(this.activeCategory === index ? ChatUi.SEARCH_BG : Color.Transparent)
            .onClick((): void => {
              this.activeCategory = index;
            })
        }, (cat: EmojiCategory) => cat.title)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 2 })
      .alignItems(VerticalAlign.Center)

      // emoji 网格
      Grid() {
        ForEach(EmojiData.CATEGORIES[this.activeCategory].emojis, (emoji: string) => {
          GridItem() {
            Text(emoji)
              .fontSize(26)
              .width('100%')
              .height(40)
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                this.onEmojiPick(emoji);
              })
          }
        }, (emoji: string) => emoji)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .cachedCount(2)
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ---------------- 贴纸 tab（M7-A2） ----------------

  // set id 为 int64 字符串（TDLib JSON 口径，PR25 审计 P0）
  @State selectedSetId: string = '';
  @State stickerVersion: number = 0;
  private readonly stickerObserver: () => void = (): void => {
    // StickerStore 数据到达（installed/set 全量）：bump 版本驱动重渲染
    this.stickerVersion += 1;
    if (this.selectedSetId.length === 0 && StickerStore.getInstance().getInstalled().length > 0) {
      const first: Record<string, Object> | undefined = StickerStore.getInstance().getInstalled()[0];
      if (first !== undefined) {
        // stickerSetInfo.id 为 int64 → JSON 字符串（PR25 审计 P0）
        this.selectedSetId = StickerStore.readString(first, 'id');
        StickerStore.getInstance().ensureSet(this.selectedSetId);
      }
    }
  };

  aboutToAppear(): void {
    StickerStore.getInstance().ensureBase();
    StickerStore.getInstance().addObserver(this.stickerObserver);
  }

  aboutToDisappear(): void {
    StickerStore.getInstance().removeObserver(this.stickerObserver);
  }

  /** 贴纸 tab：包横滚条 + 当前包贴纸网格 */
  @Builder
  stickerPanel() {
    Column() {
      // 包横滚条（封面 40vp；选中描边）
      Row({ space: 6 }) {
        ForEach(StickerStore.getInstance().getInstalled(), (set: Record<string, Object>) => {
          StickerCell({
            sticker: InputPanel.setCover(set),
            cellSize: 40,
            round: true
          })
            .onClick((): void => {
              const setId: string = StickerStore.readString(set, 'id');
              this.selectedSetId = setId;
              StickerStore.getInstance().ensureSet(setId);
            })
        }, (set: Record<string, Object>) => `${StickerStore.readString(set, 'id')}_${this.stickerVersion}`)
        if (StickerStore.getInstance().getInstalled().length === 0) {
          Text('暂无贴纸包')
            .fontSize(12)
            .fontColor(ChatUi.TEXT_SECONDARY)
            .padding({ left: 12 })
        }
      }
      .width('100%')
      .height(48)
      .padding({ left: 10, right: 10 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(ChatUi.SEARCH_BG)

      // 当前包贴纸网格（webp 直渲；其余缩略图占位）
      Grid() {
        ForEach(StickerStore.getInstance().getSetStickers(this.selectedSetId), (sticker: Record<string, Object>) => {
          GridItem() {
            StickerCell({ sticker: sticker, cellSize: 76, round: false })
              .onClick((): void => {
                this.onStickerPick(sticker);
              })
          }
        }, (sticker: Record<string, Object>) => `${InputPanel.stickerKey(sticker)}_${this.stickerVersion}`)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .cachedCount(4)
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** GIF tab：最近 webm 动画贴纸网格（1.8.63 无 savedGifs——GIF 已并入动画贴纸） */
  @Builder
  gifPanel() {
    Column() {
      if (this.recentGifs().length === 0) {
        Column() {
          Text('发过 GIF 后会显示在这里')
            .fontSize(13)
            .fontColor(ChatUi.TEXT_SECONDARY)
            .opacity(0.7)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Grid() {
          ForEach(this.recentGifs(), (sticker: Record<string, Object>) => {
            GridItem() {
              StickerCell({ sticker: sticker, cellSize: 96, round: false })
                .onClick((): void => {
                  this.onGifPick(sticker);
                })
            }
          }, (sticker: Record<string, Object>) => `${InputPanel.stickerKey(sticker)}_g${this.stickerVersion}`)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .cachedCount(4)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 最近动画（webm）过滤 */
  private recentGifs(): Array<Record<string, Object>> {
    const all: Array<Record<string, Object>> = StickerStore.getInstance().getRecent();
    const gifs: Array<Record<string, Object>> = new Array<Record<string, Object>>();
    for (const sticker of all) {
      if (StickerStore.readString(sticker, 'format') === 'stickerFormatWebm') {
        gifs.push(sticker);
      }
    }
    return gifs;
  }

  /** 网格 key：sticker.sticker.id（int32 file id，数字唯一） */
  private static stickerKey(sticker: Record<string, Object>): number {
    const file: Object | undefined = sticker['sticker'];
    if (file !== null && typeof file === 'object' && !Array.isArray(file)) {
      const rec: Record<string, Object> = file as Record<string, Object>;
      const id: Object | undefined = rec['id'];
      if (typeof id === 'number' && Number.isFinite(id)) {
        return id;
      }
    }
    return 0;
  }

  /** 贴纸包封面：covers 首个（无则占位空 sticker——StickerCell 兜底 emoji/灰底） */
  private static setCover(set: Record<string, Object>): Record<string, Object> {
    const covers: Object | undefined = set['covers'];
    if (Array.isArray(covers)) {
      const arr: Array<Object> = covers as Array<Object>;
      if (arr.length > 0) {
        const first: Object | undefined = arr[0];
        if (first !== null && typeof first === 'object' && !Array.isArray(first)) {
          return first as Record<string, Object>;
        }
      }
    }
    return { 'emoji': '·' } as Record<string, Object>;
  }
}

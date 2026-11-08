import { TdClient } from '../tdlib/TdClient';

// M1 连通验证：TDLib 版本探测（td_execute(getVersion)）的状态文案
const TD_STATUS_PROBING: string = 'TDLib 连接中…';
const TD_STATUS_OK_PREFIX: string = 'TDLib';
const TD_STATUS_OK_SUFFIX: string = '· connected';
const TD_STATUS_ERROR: string = 'TDLib 未连通（td_execute 不可用）';

// 布局尺寸（单位：vp）
const NAV_RAIL_WIDTH: number = 60;
const CHAT_LIST_WIDTH: number = 280;

// 深色系配色（Telegram 风格深蓝）
const COLOR_NAV_BG: string = '#0E1621';
const COLOR_LIST_BG: string = '#17212B';
const COLOR_CHAT_BG: string = '#0E1621';
const COLOR_SEARCH_BG: string = '#242F3D';
const COLOR_ACCENT: string = '#3390EC';
const COLOR_AVATAR_BG: string = '#2B5278';
const COLOR_TEXT_SECONDARY: string = '#7D8E9E';
const COLOR_STATUS_ERROR: string = '#FF6B6B';

/**
 * M0 占位首页：桌面三栏空壳。
 * 左：60vp 导航条（头像占位圆 + 设置图标占位）
 * 中：280vp 会话列表列（搜索框占位 + 空列表）
 * 右：聊天区（空态提示 + M1 TDLib 连通验证状态）
 */
@Entry
@Component
struct Index {
  // M1 验收 UI 载体：td_execute 连通后显示 "TDLib 1.8.63 · connected"，失败显示错误态
  @State tdStatusText: string = TD_STATUS_PROBING;
  @State tdConnected: boolean = false;

  aboutToAppear(): void {
    this.probeTdlib();
  }

  // 页面加载后同步执行 getVersion（登录前配置类请求，走 td_execute 不依赖接收线程）
  private probeTdlib(): void {
    try {
      const request: Record<string, Object> = { '@type': 'getVersion' };
      const response: Record<string, Object> = TdClient.getInstance().execute(request);
      const rawVersion: Object | undefined = response['version'];
      if (rawVersion === undefined) {
        this.tdStatusText = TD_STATUS_ERROR;
        return;
      }
      this.tdStatusText = `${TD_STATUS_OK_PREFIX} ${String(rawVersion)} ${TD_STATUS_OK_SUFFIX}`;
      this.tdConnected = true;
    } catch (error) {
      this.tdStatusText = TD_STATUS_ERROR;
      this.tdConnected = false;
    }
  }

  build() {
    Row() {
      this.navRail()
      this.chatListColumn()
      this.chatArea()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_NAV_BG)
  }

  // 左侧导航条
  @Builder
  navRail() {
    Column() {
      // 头像占位圆
      Stack() {
        Circle({ width: 34, height: 34 })
          .fill(COLOR_AVATAR_BG)
        Circle({ width: 14, height: 14 })
          .fill(COLOR_NAV_BG)
      }
      .margin({ top: 16 })

      Blank()

      // 设置图标占位（滑杆样式）
      Column({ space: 7 }) {
        Row({ space: 4 }) {
          Rect({ width: 8, height: 2 }).fill(COLOR_TEXT_SECONDARY)
          Circle({ width: 4, height: 4 }).fill(COLOR_TEXT_SECONDARY)
          Rect({ width: 10, height: 2 }).fill(COLOR_TEXT_SECONDARY)
        }
        Row({ space: 4 }) {
          Rect({ width: 12, height: 2 }).fill(COLOR_TEXT_SECONDARY)
          Circle({ width: 4, height: 4 }).fill(COLOR_TEXT_SECONDARY)
          Rect({ width: 6, height: 2 }).fill(COLOR_TEXT_SECONDARY)
        }
        Row({ space: 4 }) {
          Rect({ width: 4, height: 2 }).fill(COLOR_TEXT_SECONDARY)
          Circle({ width: 4, height: 4 }).fill(COLOR_TEXT_SECONDARY)
          Rect({ width: 14, height: 2 }).fill(COLOR_TEXT_SECONDARY)
        }
      }
      .margin({ bottom: 18 })
    }
    .width(NAV_RAIL_WIDTH)
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  // 中间会话列表列
  @Builder
  chatListColumn() {
    Column() {
      // 搜索框占位
      Row({ space: 8 }) {
        // 放大镜占位：圆环 + 斜置短柄
        Stack() {
          Circle({ width: 13, height: 13 })
            .fillOpacity(0)
            .stroke(COLOR_TEXT_SECONDARY)
            .strokeWidth(1.5)
          Rect({ width: 6, height: 2 })
            .fill(COLOR_TEXT_SECONDARY)
            .rotate({ angle: 45 })
            .offset({ x: 7, y: 5 })
        }
        .width(15)
        .height(15)
        Text($r('app.string.search_placeholder'))
          .fontSize(14)
          .fontColor(COLOR_TEXT_SECONDARY)
      }
      .width('92%')
      .height(34)
      .padding({ left: 12, right: 12 })
      .borderRadius(17)
      .backgroundColor(COLOR_SEARCH_BG)
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)

      // 空会话列表
      Column() {
        Text($r('app.string.chat_list_empty'))
          .fontSize(13)
          .fontColor(COLOR_TEXT_SECONDARY)
          .opacity(0.7)
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width(CHAT_LIST_WIDTH)
    .height('100%')
    .backgroundColor(COLOR_LIST_BG)
    .alignItems(HorizontalAlign.Center)
  }

  // 右侧聊天区（空态）
  @Builder
  chatArea() {
    Column() {
      Blank()
      Image($r('app.media.tg_plane'))
        .width(56)
        .height(56)
        .fillColor(COLOR_ACCENT)
        .opacity(0.85)
      Text($r('app.string.chat_area_placeholder'))
        .fontSize(16)
        .fontColor(COLOR_TEXT_SECONDARY)
        .margin({ top: 16 })
      // M1 连通验证状态：成功为主题蓝、失败为警示红（探测中为次要色）
      Text(this.tdStatusText)
        .fontSize(13)
        .fontColor(this.tdConnected ? COLOR_ACCENT : (this.tdStatusText === TD_STATUS_PROBING
          ? COLOR_TEXT_SECONDARY : COLOR_STATUS_ERROR))
        .opacity(0.9)
        .margin({ top: 8 })
      Blank()
    }
    .layoutWeight(1)
    .height('100%')
    .backgroundColor(COLOR_CHAT_BG)
  }
}

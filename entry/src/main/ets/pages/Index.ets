/**
 * 主页（M2）：三栏响应式 + 会话列表 + 认证路由观察者。
 *
 * 响应式（断点见 core/BreakpointTool，PLAN §4）：
 * - lg ≥840vp：导航条 + 会话列表 + 聊天区 三栏（桌面全量形态）
 * - md 600~840vp：会话列表 + 聊天区 两栏（导航条收纳）
 * - sm <600vp：会话列表单栏全宽（导航条收纳为顶部标题栏，聊天区隐藏，点击会话推入 ChatPage）
 *
 * 登录流程的状态驱动跳转唯一入口在本页（Index 常驻栈底不销毁，观察者持续有效）。
 * 登录页只负责提交动作；authState 变化 → 本页路由到对应流程页。
 *
 * 安全区策略：应用未开 setWindowLayoutFullScreen 全屏布局，系统默认避让状态栏/手势条，
 * 页根组件不主动延伸安全区——真机（手机挖孔/手势条）验证挂 M2 验收。
 */
import { router } from '@kit.ArkUI';
import { TdClient } from '../tdlib/TdClient';
import { AuthService, AppAuthState, AuthStateObserver } from '../core/AuthService';
import { AuthStateType } from '../core/TdConstants';
import { ChatListStore, ChatListObserver } from '../core/ChatListStore';
import { MessageStore } from '../core/MessageStore';
import { FileDownloadStore } from '../core/FileDownloadStore';
import { BreakpointTool, Breakpoint, BreakpointObserver } from '../core/BreakpointTool';
import { ChatUi, ChatRowModel } from './ChatUi';
import { ChatListDataSource } from './ChatListDataSource';
import { ChatPanel } from '../components/ChatPanel';

/** 认证状态 → 中文提示（M2 复审建议：技术串不直出用户 UI） */
class AuthStateTextMap {
  static toText(state: string): string {
    switch (state) {
      case AppAuthState.INITIAL:
      case AppAuthState.TD_INITIALIZING:
        return '初始化中…';
      case AppAuthState.CREDENTIALS_MISSING:
        return '待配置 API 凭证';
      case AppAuthState.CREDENTIALS_ERROR:
        return '凭证校验失败';
      case AppAuthState.WAIT_TDLIB_PARAMETERS:
        return '待配置参数';
      case AppAuthState.WAIT_PHONE_NUMBER:
        return '待输入手机号';
      case AuthStateType.WAIT_CODE:
        return '待输入验证码';
      case AuthStateType.WAIT_PASSWORD:
        return '待输入两步验证密码';
      case AuthStateType.WAIT_REGISTRATION:
        return '待注册';
      case AuthStateType.WAIT_EMAIL_ADDRESS:
        return '待输入邮箱';
      case AuthStateType.WAIT_EMAIL_CODE:
        return '待输入邮箱验证码';
      case AuthStateType.WAIT_OTHER_DEVICE:
        return '待其他设备确认';
      case AppAuthState.READY:
        return '已就绪';
      case AuthStateType.LOGGING_OUT:
        return '登出中…';
      default:
        return state;
    }
  }
}

// M1 连通验证：TDLib 版本探测（td_execute(getVersion)）
const TD_STATUS_ERROR: string = 'TDLib 未连通（td_execute 不可用）';

// 布局尺寸（单位：vp）
const NAV_RAIL_WIDTH: number = 60;
const CHAT_LIST_WIDTH: number = 300;
const ROW_HEIGHT: number = 64;
const AVATAR_SIZE: number = 46;

const PAGE_CREDENTIALS: string = 'pages/CredentialsPage';
const PAGE_LOGIN: string = 'pages/LoginPage';
const PAGE_VERIFY: string = 'pages/VerifyCodePage';
const PAGE_PASSWORD: string = 'pages/PasswordPage';
const PAGE_CHAT: string = 'pages/ChatPage';
const PAGE_PROXY: string = 'pages/ProxyPage';

/**
 * 首页：响应式三栏 + 会话列表 + TDLib 连通状态 + 认证路由。
 */
@Entry
@Component
struct Index {
  @State tdStatusText: string = 'TDLib 检测中…';
  @State tdConnected: boolean = false;
  @State authStateText: string = '';
  @State loggedIn: boolean = false;
  @State breakpoint: string = Breakpoint.SM;
  @State searchText: string = '';
  @State visibleCount: number = 0;
  @State selectedChatId: number = 0;
  @State selectedChatTitle: string = '';
  // LazyForEach 数据源（非 @State：内部经 onDataReloaded 自通知）
  private dataSource: ChatListDataSource = new ChatListDataSource();
  private lastRoutedState: string = '';
  // 观察者提为成员属性：aboutToDisappear 注销，防泄漏（M2 复审 MEDIUM 修复沿用）
  private readonly authObserver: AuthStateObserver = (appState: string, raw: Record<string, Object>): void => {
    this.authStateText = AuthStateTextMap.toText(appState);
    this.loggedIn = appState === AppAuthState.READY;
    this.syncChatStoreLifecycle(appState);
    this.handleAuthRoute(appState);
  };
  private readonly breakpointObserver: BreakpointObserver = (breakpoint: string): void => {
    this.breakpoint = breakpoint;
  };
  private readonly listObserver: ChatListObserver = (): void => {
    this.refreshVisibleCount();
  };

  aboutToAppear(): void {
    this.probeTdlib();
    AuthService.getInstance().start();
    AuthService.getInstance().onAuthState(this.authObserver);
    BreakpointTool.getInstance().addObserver(this.breakpointObserver);
    ChatListStore.getInstance().addObserver(this.listObserver);
    this.refreshVisibleCount();
  }

  aboutToDisappear(): void {
    AuthService.getInstance().offAuthState(this.authObserver);
    BreakpointTool.getInstance().removeObserver(this.breakpointObserver);
    ChatListStore.getInstance().removeObserver(this.listObserver);
    this.dataSource.dispose();
  }

  /** 会话仓库生命周期：ready 拉首屏；离开 ready（登出/重登）重置，authState 流转自动回登录页 */
  private syncChatStoreLifecycle(appState: string): void {
    if (appState === AppAuthState.READY) {
      ChatListStore.getInstance().start();
      MessageStore.getInstance().start();
      FileDownloadStore.getInstance().start();
    } else {
      ChatListStore.getInstance().reset();
      MessageStore.getInstance().reset();
      FileDownloadStore.getInstance().reset();
      this.selectedChatId = 0;
      this.selectedChatTitle = '';
    }
  }

  private refreshVisibleCount(): void {
    this.visibleCount = this.dataSource.totalCount();
    if (this.selectedChatId !== 0) {
      const title: string = ChatListStore.getInstance().getTitle(this.selectedChatId);
      if (title.length > 0) {
        this.selectedChatTitle = title;
      }
    }
  }

  // M1 验收载体：td_execute getVersion（登录前配置类请求，纯内存瞬时返回）
  private probeTdlib(): void {
    try {
      const request: Record<string, Object> = { '@type': 'getVersion' };
      const response: Record<string, Object> = TdClient.getInstance().execute(request);
      const rawVersion: Object | undefined = response['version'];
      if (rawVersion === undefined) {
        this.tdStatusText = TD_STATUS_ERROR;
        return;
      }
      this.tdStatusText = `TDLib ${String(rawVersion)} · connected`;
      this.tdConnected = true;
    } catch (error) {
      this.tdStatusText = TD_STATUS_ERROR;
      this.tdConnected = false;
    }
  }

  /** 认证状态驱动路由（防重：同状态只路由一次；流程页通过 pushUrl 压栈保留 back 语义） */
  private handleAuthRoute(appState: string): void {
    if (appState === this.lastRoutedState) {
      return;
    }
    this.lastRoutedState = appState;
    switch (appState) {
      case AppAuthState.CREDENTIALS_MISSING:
        this.routeToPage(PAGE_CREDENTIALS);
        break;
      case AppAuthState.CREDENTIALS_ERROR:
        // 冷启动存量凭证失效：引导回凭证页修改（M2 复审 L4 修复）
        this.routeToPage(PAGE_CREDENTIALS);
        break;
      case AppAuthState.WAIT_PHONE_NUMBER:
        this.routeToPage(PAGE_LOGIN);
        break;
      case AuthStateType.WAIT_CODE:
        this.routeToPage(PAGE_VERIFY);
        break;
      case AuthStateType.WAIT_PASSWORD:
        this.routeToPage(PAGE_PASSWORD);
        break;
      case AppAuthState.READY:
        // 登录完成：清登录流程栈，回到本页（重建实例重新探测，无害）
        if (Number.parseInt(router.getLength()) > 1) {
          router.clear();
          router.replaceUrl({ url: 'pages/Index' });
        }
        break;
      default:
        break;
    }
  }

  private routeToPage(url: string): void {
    router.pushUrl({ url: url }).catch((err: Error): void => {
      console.error(`route to ${url} failed: ${err.message}`);
    });
  }

  /** 设置菜单（导航条/顶部栏共用）：代理设置 / 登出 */
  private settingsMenu(): Array<MenuElement> {
    const items: Array<MenuElement> = [
      {
        value: '代理设置',
        action: (): void => {
          this.routeToPage(PAGE_PROXY);
        }
      },
      {
        value: '登出',
        action: (): void => {
          // TDLib logOut → authorizationStateLoggingOut → waitPhoneNumber，Index 观察者自动回登录页
          AuthService.getInstance().logOut();
        }
      }
    ];
    return items;
  }

  private openChat(row: ChatRowModel): void {
    if (row.chatId === 0) {
      return;
    }
    if (this.breakpoint === Breakpoint.SM) {
      const params: Record<string, Object> = { 'chatId': row.chatId };
      router.pushUrl({ url: PAGE_CHAT, params: params }).catch((err: Error): void => {
        console.error(`route to chat failed: ${err.message}`);
      });
      return;
    }
    // md/lg：右侧聊天区内嵌 ChatPanel（消息流 + 输入区，与 sm ChatPage 复用同一组件）
    this.selectedChatId = row.chatId;
    this.selectedChatTitle = ChatListStore.getInstance().getTitle(row.chatId);
  }

  build() {
    Row() {
      if (this.breakpoint === Breakpoint.LG) {
        this.navRail()
      }
      this.chatListColumn()
      if (this.breakpoint !== Breakpoint.SM) {
        this.chatArea()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ChatUi.CHAT_BG)
  }

  // 左侧导航条（仅 lg）
  @Builder
  navRail() {
    Column() {
      // 头像占位圆（本人头像 M3 接 getMe）
      Stack() {
        Circle({ width: 34, height: 34 })
          .fill(ChatUi.ACCENT)
        Circle({ width: 14, height: 14 })
          .fill(ChatUi.NAV_BG)
      }
      .margin({ top: 16 })

      Blank()

      // 设置入口：菜单（代理设置 / 登出）
      Column({ space: 7 }) {
        Row({ space: 4 }) {
          Rect({ width: 8, height: 2 }).fill(ChatUi.TEXT_SECONDARY)
          Circle({ width: 4, height: 4 }).fill(ChatUi.TEXT_SECONDARY)
          Rect({ width: 10, height: 2 }).fill(ChatUi.TEXT_SECONDARY)
        }
        Row({ space: 4 }) {
          Rect({ width: 12, height: 2 }).fill(ChatUi.TEXT_SECONDARY)
          Circle({ width: 4, height: 4 }).fill(ChatUi.TEXT_SECONDARY)
          Rect({ width: 6, height: 2 }).fill(ChatUi.TEXT_SECONDARY)
        }
        Row({ space: 4 }) {
          Rect({ width: 4, height: 2 }).fill(ChatUi.TEXT_SECONDARY)
          Circle({ width: 4, height: 4 }).fill(ChatUi.TEXT_SECONDARY)
          Rect({ width: 14, height: 2 }).fill(ChatUi.TEXT_SECONDARY)
        }
      }
      .margin({ bottom: 18 })
      .bindMenu(this.settingsMenu())
    }
    .width(NAV_RAIL_WIDTH)
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(ChatUi.NAV_BG)
  }

  // 顶部标题栏（仅 sm：导航条收纳，设置入口保留）
  @Builder
  smTopBar() {
    Row() {
      Text('Telegram')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(ChatUi.TEXT_PRIMARY)
      Blank()
      Text('···')
        .fontSize(18)
        .fontColor(ChatUi.TEXT_SECONDARY)
        .width(36)
        .height(36)
        .textAlign(TextAlign.Center)
        .bindMenu(this.settingsMenu())
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 10 })
    .alignItems(VerticalAlign.Center)
  }

  // 会话列表列（sm 全宽 / md、lg 固定宽）
  @Builder
  chatListColumn() {
    Column() {
      if (this.breakpoint === Breakpoint.SM) {
        this.smTopBar()
      }

      // 搜索框（M2：本地过滤已加载会话；服务端搜索见 ChatListDataSource 头注释）
      TextInput({ text: this.searchText, placeholder: $r('app.string.search_placeholder') })
        .width('92%')
        .height(34)
        .borderRadius(17)
        .backgroundColor(ChatUi.SEARCH_BG)
        .fontColor(ChatUi.TEXT_PRIMARY)
        .fontSize(14)
        .placeholderColor(ChatUi.TEXT_SECONDARY)
        .placeholderFont({ size: 14 })
        .padding({ left: 14, right: 14 })
        .margin({ top: 10, bottom: 6 })
        .onChange((value: string): void => {
          this.searchText = value;
          this.dataSource.setKeyword(value);
          this.refreshVisibleCount();
        })

      if (this.visibleCount === 0) {
        this.listEmptyState()
      } else {
        List({ space: 0 }) {
          LazyForEach(this.dataSource, (item: ChatRowModel) => {
            ListItem() {
              this.chatRow(item)
            }
          }, (item: ChatRowModel) => `${item.chatId}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        // 滚动到底自动分页（loadChats；全部加载后仓库侧自动熔断）
        .onReachEnd((): void => {
          ChatListStore.getInstance().loadMore();
        })
      }
    }
    .width(this.breakpoint === Breakpoint.SM ? '100%' : CHAT_LIST_WIDTH)
    .height('100%')
    .backgroundColor(ChatUi.LIST_BG)
    .alignItems(HorizontalAlign.Center)
  }

  // 空态：搜索无结果 / 未登录认证阶段提示
  @Builder
  listEmptyState() {
    Column() {
      if (this.dataSource.getKeyword().length > 0) {
        Text('未找到匹配会话')
          .fontSize(13)
          .fontColor(ChatUi.TEXT_SECONDARY)
          .opacity(0.7)
      } else {
        Text($r('app.string.chat_list_empty'))
          .fontSize(13)
          .fontColor(ChatUi.TEXT_SECONDARY)
          .opacity(0.7)
        // M2 登录链路验证期：非登录态在列表区提示当前认证阶段
        if (!this.loggedIn && this.authStateText.length > 0) {
          Text(`认证阶段: ${this.authStateText}`)
            .fontSize(11)
            .fontColor(ChatUi.TEXT_SECONDARY)
            .opacity(0.5)
            .margin({ top: 8 })
        }
      }
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  // 会话行：头像占位（首字母圆环）+ 标题 + 预览 + 相对时间 + 未读角标 + 置顶标记
  @Builder
  chatRow(item: ChatRowModel) {
    Row({ space: 12 }) {
      Stack() {
        Circle({ width: AVATAR_SIZE, height: AVATAR_SIZE })
          .fill(ChatUi.avatarColor(item.chatId))
        Text(ChatUi.avatarLetter(item.title))
          .fontSize(19)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .width(AVATAR_SIZE)
      .height(AVATAR_SIZE)

      Column({ space: 4 }) {
        Row() {
          Text(item.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(ChatUi.TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(item.timeText)
            .fontSize(11)
            .fontColor(ChatUi.TEXT_SECONDARY)
            .margin({ left: 8 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row() {
          Text(item.preview)
            .fontSize(13)
            .fontColor(ChatUi.TEXT_SECONDARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (item.pinned) {
            Text('置顶')
              .fontSize(10)
              .fontColor(ChatUi.TEXT_SECONDARY)
              .margin({ left: 8 })
          }
          if (item.unreadText.length > 0) {
            Text(item.unreadText)
              .fontSize(11)
              .fontColor('#FFFFFF')
              .constraintSize({ minWidth: 20 })
              .height(20)
              .borderRadius(10)
              .textAlign(TextAlign.Center)
              .padding({ left: 6, right: 6 })
              .backgroundColor(ChatUi.BADGE_BG)
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: 10, right: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.openChat(item);
    })
  }

  // 右侧聊天区（md/lg）：空态欢迎 / ChatPanel 内嵌（M3 组件化，消息流+输入区与 sm 复用）
  @Builder
  chatArea() {
    Column() {
      if (this.selectedChatId !== 0) {
        Row() {
          Text(this.selectedChatTitle)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ChatUi.TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .height(52)
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(ChatUi.LIST_BG)

        ChatPanel({ chatId: this.selectedChatId })
      } else {
        Column() {
          Blank()
          Image($r('app.media.tg_plane'))
            .width(56)
            .height(56)
            .fillColor(ChatUi.ACCENT)
            .opacity(0.85)
          if (this.loggedIn) {
            Text('已登录 Telegram')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(ChatUi.TEXT_PRIMARY)
              .margin({ top: 16 })
            Text('在左侧选择一个会话')
              .fontSize(13)
              .fontColor(ChatUi.TEXT_SECONDARY)
              .margin({ top: 6 })
          } else {
            Text($r('app.string.chat_area_placeholder'))
              .fontSize(16)
              .fontColor(ChatUi.TEXT_SECONDARY)
              .margin({ top: 16 })
          }
          Text(this.tdStatusText)
            .fontSize(13)
            .fontColor(this.tdConnected ? ChatUi.ACCENT : '#FF6B6B')
            .opacity(0.9)
            .margin({ top: 8 })
          Blank()
        }
        .width('100%')
        .height('100%')
      }
    }
    .layoutWeight(1)
    .height('100%')
    .backgroundColor(ChatUi.CHAT_BG)
  }
}

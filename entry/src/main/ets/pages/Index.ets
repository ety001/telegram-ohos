/**
 * 主页（M2）：桌面三栏 + 认证路由观察者。
 * 登录流程的状态驱动跳转唯一入口在本页（Index 常驻栈底不销毁，观察者持续有效）。
 * 登录页只负责提交动作；authState 变化 → 本页路由到对应流程页。
 */
import { router } from '@kit.ArkUI';
import { TdClient } from '../tdlib/TdClient';
import { AuthService, AppAuthState, AuthStateObserver } from '../core/AuthService';
import { AuthStateType } from '../core/TdConstants';
import { AuthUi } from './AuthUi';

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
const CHAT_LIST_WIDTH: number = 280;

// 深色系配色（Telegram 风格深蓝）
const COLOR_NAV_BG: string = '#0E1621';
const COLOR_LIST_BG: string = '#17212B';
const COLOR_CHAT_BG: string = '#0E1621';
const COLOR_SEARCH_BG: string = '#242F3D';
const COLOR_ACCENT: string = '#3390EC';
const COLOR_AVATAR_BG: string = '#2B5278';
const COLOR_TEXT_PRIMARY: string = '#F5F5F5';
const COLOR_TEXT_SECONDARY: string = '#7D8E9E';
const COLOR_STATUS_ERROR: string = '#FF6B6B';

const PAGE_CREDENTIALS: string = 'pages/CredentialsPage';
const PAGE_LOGIN: string = 'pages/LoginPage';
const PAGE_VERIFY: string = 'pages/VerifyCodePage';
const PAGE_PASSWORD: string = 'pages/PasswordPage';

/**
 * 首页：三栏空壳 + TDLib 连通状态 + 认证路由。
 * 登录就绪（ready）后本页即为会话主界面骨架；会话列表在 M2 后续 PR 接入。
 */
@Entry
@Component
struct Index {
  @State tdStatusText: string = 'TDLib 检测中…';
  @State tdConnected: boolean = false;
  @State authStateText: string = '';
  @State loggedIn: boolean = false;
  private lastRoutedState: string = '';
  // 观察者提为成员属性：aboutToDisappear 注销，防 ready 重建实例后泄漏（M2 复审 MEDIUM 修复）
  private readonly authObserver: AuthStateObserver = (appState: string, raw: Record<string, Object>): void => {
    this.authStateText = AuthStateTextMap.toText(appState);
    this.loggedIn = appState === AppAuthState.READY;
    this.handleAuthRoute(appState);
  };

  aboutToAppear(): void {
    this.probeTdlib();
    AuthService.getInstance().start();
    AuthService.getInstance().onAuthState(this.authObserver);
  }

  aboutToDisappear(): void {
    AuthService.getInstance().offAuthState(this.authObserver);
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

      // 设置入口（M2：代理设置）
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
      .onClick((): void => {
        router.pushUrl({ url: 'pages/ProxyPage' });
      })
    }
    .width(NAV_RAIL_WIDTH)
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  // 中间会话列表列
  @Builder
  chatListColumn() {
    Column() {
      Row({ space: 8 }) {
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

      Column() {
        Text($r('app.string.chat_list_empty'))
          .fontSize(13)
          .fontColor(COLOR_TEXT_SECONDARY)
          .opacity(0.7)
        // M2 登录链路验证期：非登录态在列表区提示当前认证阶段
        if (!this.loggedIn && this.authStateText.length > 0) {
          Text(`认证阶段: ${this.authStateText}`)
            .fontSize(11)
            .fontColor(COLOR_TEXT_SECONDARY)
            .opacity(0.5)
            .margin({ top: 8 })
        }
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

  // 右侧聊天区（空态 / 登录就绪欢迎态）
  @Builder
  chatArea() {
    Column() {
      Blank()
      Image($r('app.media.tg_plane'))
        .width(56)
        .height(56)
        .fillColor(COLOR_ACCENT)
        .opacity(0.85)
      if (this.loggedIn) {
        Text('已登录 Telegram')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT_PRIMARY)
          .margin({ top: 16 })
        Text('会话列表将在后续版本接入')
          .fontSize(13)
          .fontColor(COLOR_TEXT_SECONDARY)
          .margin({ top: 6 })
      } else {
        Text($r('app.string.chat_area_placeholder'))
          .fontSize(16)
          .fontColor(COLOR_TEXT_SECONDARY)
          .margin({ top: 16 })
      }
      Text(this.tdStatusText)
        .fontSize(13)
        .fontColor(this.tdConnected ? COLOR_ACCENT : COLOR_STATUS_ERROR)
        .opacity(0.9)
        .margin({ top: 8 })
      Blank()
    }
    .layoutWeight(1)
    .height('100%')
    .backgroundColor(COLOR_CHAT_BG)
  }
}

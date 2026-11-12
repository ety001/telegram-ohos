/**
 * 设置页（M6-8）：通知预览开关 / 代理设置入口 / 登出 / 关于（版本信息）。
 *
 * - 通知预览：ConfigStore.notify_preview 持久化，关闭后本地通知正文固定「你有一条新消息」
 *   （NotificationService 组装时分流），标题仍为会话名；
 * - 关于：应用版本（app.json5 versionName 硬编码镜像，与 AppScope 同步维护）+
 *   TDLib 版本（td_execute getOption(version) 同步探测，1.8.63 契约仅此两项可同步）；
 * - 登出：TDLib logOut → authorizationStateLoggingOut 流转，Index 观察者自动回登录页
 *   （二次确认 AlertDialog，防误触——比原 Index 菜单直出更稳）。
 */
import { router } from '@kit.ArkUI';
import { ChatUi } from './ChatUi';
import { AuthService } from '../core/AuthService';
import { ConfigStore } from '../core/ConfigStore';
import { TdClient } from '../tdlib/TdClient';
import { TdReq, TdField, ErrorType } from '../core/TdConstants';

/** 应用版本（与 AppScope/app.json5 versionName 同步维护） */
const APP_VERSION: string = '0.3.0';

@Entry
@Component
struct SettingsPage {
  @State notifyPreview: boolean = true;
  @State tdlibVersion: string = '';

  aboutToAppear(): void {
    ConfigStore.getNotifyPreview()
      .then((enable: boolean): void => {
        this.notifyPreview = enable;
      })
      .catch((): void => {
      });
    this.probeTdlibVersion();
  }

  build() {
    Column() {
      // 顶栏：返回 + 标题
      Row({ space: 12 }) {
        Text('<')
          .fontSize(24)
          .fontColor(ChatUi.TEXT_PRIMARY)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            router.back();
          })
        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ChatUi.TEXT_PRIMARY)
      }
      .width('100%')
      .height(52)
      .padding({ left: 14, right: 16 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(ChatUi.LIST_BG)

      List({ space: 0 }) {
        // 通知预览
        ListItem() {
          Row({ space: 12 }) {
            Column({ space: 2 }) {
              Text('通知预览')
                .fontSize(15)
                .fontColor(ChatUi.TEXT_PRIMARY)
              Text('关闭后通知不显示消息内容')
                .fontSize(12)
                .fontColor(ChatUi.TEXT_SECONDARY)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.notifyPreview })
              .onChange((isOn: boolean): void => {
                this.notifyPreview = isOn;
                ConfigStore.putNotifyPreview(isOn).catch((): void => {
                });
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)
        }

        // 代理设置入口
        ListItem() {
          Row() {
            Text('代理设置')
              .fontSize(15)
              .fontColor(ChatUi.TEXT_PRIMARY)
              .layoutWeight(1)
            Text('>')
              .fontSize(16)
              .fontColor(ChatUi.TEXT_SECONDARY)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            router.pushUrl({ url: 'pages/ProxyPage' }).catch((): void => {
            });
          })
        }

        // 登出
        ListItem() {
          Row() {
            Text('登出账号')
              .fontSize(15)
              .fontColor(ChatUi.BUBBLE_ERROR)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.confirmLogout();
          })
        }

        // 关于
        ListItem() {
          Column({ space: 6 }) {
            Row() {
              Text('应用版本')
                .fontSize(15)
                .fontColor(ChatUi.TEXT_PRIMARY)
                .layoutWeight(1)
              Text(APP_VERSION)
                .fontSize(13)
                .fontColor(ChatUi.TEXT_SECONDARY)
            }
            .width('100%')
            Row() {
              Text('TDLib 版本')
                .fontSize(15)
                .fontColor(ChatUi.TEXT_PRIMARY)
                .layoutWeight(1)
              Text(this.tdlibVersion.length > 0 ? this.tdlibVersion : '1.8.63')
                .fontSize(13)
                .fontColor(ChatUi.TEXT_SECONDARY)
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(ChatUi.CHAT_BG)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ChatUi.CHAT_BG)
  }

  /** 登出二次确认（AlertDialog）：logOut 触发授权状态机流转自动回登录页 */
  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({
      title: '登出账号',
      message: '确定退出当前账号？本地登录态将清除（消息数据库保留，重新登录后可继续查看）。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '登出',
        fontColor: ChatUi.BUBBLE_ERROR,
        action: (): void => {
          AuthService.getInstance().logOut();
        }
      }
    });
  }

  /** td_execute 同步探测 TDLib 版本（1.8.63 契约：getOption(version) 可同步调用） */
  private probeTdlibVersion(): void {
    try {
      const request: Record<string, Object> = { '@type': TdReq.GET_OPTION, 'name': 'version' };
      const response: Record<string, Object> = TdClient.getInstance().execute(request);
      const typeObj: Object | undefined = response[TdField.TYPE];
      if (typeObj === ErrorType.INVALID) {
        return;
      }
      const valueObj: Object | undefined = response[TdField.VALUE];
      if (typeof valueObj === 'string' && valueObj.length > 0) {
        this.tdlibVersion = valueObj;
      }
    } catch (err) {
      // 探测失败保持默认显示
    }
  }
}

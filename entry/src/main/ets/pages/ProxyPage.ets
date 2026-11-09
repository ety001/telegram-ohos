/**
 * 代理设置页（M2 简版）：国内登录 DC 硬前置。
 * 支持 SOCKS5 / MTProto；保存 + 连通测试（testProxy 走 @extra 更新流）。
 */
import { router } from '@kit.ArkUI';
import { AuthService } from '../core/AuthService';
import { ConfigStore, ProxyConfig } from '../core/ConfigStore';
import { AuthUi } from './AuthUi';

const TYPE_SOCKS5: string = 'socks5';
const TYPE_MTPROTO: string = 'mtproto';

@Entry
@Component
struct ProxyPage {
  @State host: string = '';
  @State portText: string = '';
  @State user: string = '';
  @State password: string = '';
  @State proxyType: string = TYPE_SOCKS5;
  @State selectedIndex: number = 0;
  @State enable: boolean = true;
  @State busy: boolean = false;
  @State resultText: string = '';
  @State resultOk: boolean = false;

  aboutToAppear(): void {
    ConfigStore.getProxy().then((config: ProxyConfig | null): void => {
      if (config !== null) {
        this.host = config.host;
        this.portText = `${config.port}`;
        this.user = config.user;
        this.password = config.password;
        this.proxyType = config.proxyType;
        this.selectedIndex = config.proxyType === TYPE_MTPROTO ? 1 : 0;
        this.enable = config.enable;
      }
    }).catch((): void => {
      // 首次进入无配置，保持空表单
    });
  }

  private buildConfig(): ProxyConfig {
    const config: ProxyConfig = {
      host: this.host.trim(),
      port: Number.parseInt(this.portText.trim()),
      user: this.user.trim(),
      password: this.password,
      proxyType: this.proxyType,
      enable: this.enable
    };
    return config;
  }

  private validate(config: ProxyConfig): string {
    if (config.host.length === 0) {
      return '服务器地址不能为空';
    }
    if (Number.isNaN(config.port) || config.port <= 0 || config.port > 65535) {
      return '端口须为 1-65535';
    }
    return '';
  }

  private saveAndApply(): void {
    const config: ProxyConfig = this.buildConfig();
    const invalid: string = this.validate(config);
    if (invalid.length > 0) {
      this.resultText = invalid;
      this.resultOk = false;
      return;
    }
    this.busy = true;
    this.resultText = '';
    // 消费 applyProxy 的 Promise：addProxy 被拒（如代理格式错误）时显示真实结果（M2 复审 M1 修复）
    AuthService.getInstance().applyProxy(config).then((): Promise<void> => {
      return ConfigStore.putProxy(config);
    }).then((): void => {
      this.busy = false;
      this.resultText = '已保存并应用';
      this.resultOk = true;
    }).catch((err: Error): void => {
      this.busy = false;
      this.resultText = `应用失败: ${err.message}`;
      this.resultOk = false;
    });
  }

  private test(): void {
    const config: ProxyConfig = this.buildConfig();
    const invalid: string = this.validate(config);
    if (invalid.length > 0) {
      this.resultText = invalid;
      this.resultOk = false;
      return;
    }
    this.busy = true;
    this.resultText = '测试中…';
    AuthService.getInstance().testProxy(config)
      .then((): void => {
        this.busy = false;
        this.resultText = '连通 ✓';
        this.resultOk = true;
      })
      .catch((err: Error): void => {
        this.busy = false;
        this.resultText = `连通失败: ${err.message}`;
        this.resultOk = false;
      });
  }

  build() {
    Column({ space: 14 }) {
      Text('代理设置')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(AuthUi.TEXT_PRIMARY)
      Text('国内网络直连 Telegram DC 不通，登录前请配置代理（如本机 mihomo 的 SOCKS5 端口）。')
        .fontSize(13)
        .fontColor(AuthUi.TEXT_SECONDARY)
        .lineHeight(18)

      Row({ space: 12 }) {
        Text('类型').fontSize(13).fontColor(AuthUi.TEXT_SECONDARY).width(56)
        Select([{ value: 'SOCKS5' }, { value: 'MTProto' }])
          .selected($$this.selectedIndex)
          .value(this.selectedIndex === 0 ? 'SOCKS5' : 'MTProto')
          .fontColor(AuthUi.TEXT_PRIMARY)
          .onSelect((index: number): void => {
            this.selectedIndex = index;
            this.proxyType = index === 0 ? TYPE_SOCKS5 : TYPE_MTPROTO;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      TextInput({ text: this.host, placeholder: '服务器地址' })
        .height(AuthUi.INPUT_HEIGHT)
        .backgroundColor(AuthUi.INPUT_BG)
        .fontColor(AuthUi.TEXT_PRIMARY)
        .onChange((value: string): void => {
          this.host = value;
        })

      TextInput({ text: this.portText, placeholder: '端口（如 7890）' })
        .type(InputType.Number)
        .height(AuthUi.INPUT_HEIGHT)
        .backgroundColor(AuthUi.INPUT_BG)
        .fontColor(AuthUi.TEXT_PRIMARY)
        .onChange((value: string): void => {
          this.portText = value;
        })

      if (this.proxyType === TYPE_SOCKS5) {
        TextInput({ text: this.user, placeholder: '用户名（可选）' })
          .height(AuthUi.INPUT_HEIGHT)
          .backgroundColor(AuthUi.INPUT_BG)
          .fontColor(AuthUi.TEXT_PRIMARY)
          .onChange((value: string): void => {
            this.user = value;
          })
        TextInput({ text: this.password, placeholder: '密码（可选）' })
          .type(InputType.Password)
          .height(AuthUi.INPUT_HEIGHT)
          .backgroundColor(AuthUi.INPUT_BG)
          .fontColor(AuthUi.TEXT_PRIMARY)
          .onChange((value: string): void => {
            this.password = value;
          })
      } else {
        TextInput({ text: this.password, placeholder: 'MTProto Secret' })
          .height(AuthUi.INPUT_HEIGHT)
          .backgroundColor(AuthUi.INPUT_BG)
          .fontColor(AuthUi.TEXT_PRIMARY)
          .onChange((value: string): void => {
            this.password = value;
          })
      }

      Row({ space: 12 }) {
        Text('启用').fontSize(13).fontColor(AuthUi.TEXT_SECONDARY)
        Toggle({ type: ToggleType.Switch, isOn: $$this.enable })
          .selectedColor(AuthUi.ACCENT)
      }
      .width('100%')

      if (this.resultText.length > 0) {
        Text(this.resultText)
          .fontSize(13)
          .fontColor(this.resultOk ? AuthUi.TEXT_OK : AuthUi.TEXT_ERROR)
      }

      Row({ space: 12 }) {
        Button('连通测试')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(AuthUi.CARD_BG)
          .fontColor(AuthUi.TEXT_PRIMARY)
          .enabled(!this.busy)
          .onClick((): void => {
            this.test();
          })
        Button('保存并应用')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(AuthUi.ACCENT)
          .enabled(!this.busy)
          .onClick((): void => {
            this.saveAndApply();
          })
      }
      .width('100%')

      Text('返回')
        .fontSize(13)
        .fontColor(AuthUi.ACCENT)
        .onClick((): void => {
          router.back();
        })
    }
    .width(AuthUi.CARD_WIDTH)
    .padding(24)
    .borderRadius(12)
    .backgroundColor(AuthUi.CARD_BG)
    .justifyContent(FlexAlign.Center)
    .height('100%')
  }
}

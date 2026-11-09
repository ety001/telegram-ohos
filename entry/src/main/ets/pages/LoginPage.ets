/**
 * 手机号输入页（M2）。提交后由 authState 驱动跳转（验证码页）。
 * 敏感信息：手机号不打日志。
 */
import { router } from '@kit.ArkUI';
import { AuthService } from '../core/AuthService';
import { AuthUi } from './AuthUi';

@Entry
@Component
struct LoginPage {
  @State phoneText: string = '';
  @State submitting: boolean = false;
  @State errorText: string = '';

  private submit(): void {
    // 规范化为纯数字国际格式（如 8613800000000）
    const digits: string = this.phoneText.replace(/[^0-9]/g, '');
    if (digits.length < 8) {
      this.errorText = '请输入完整的国际格式手机号（含国家代码）';
      return;
    }
    this.submitting = true;
    this.errorText = '';
    AuthService.getInstance().requestPhoneNumber(digits)
      .then((): void => {
        this.submitting = false;
        // 状态推进到 waitCode 后由 Index 路由观察者跳转验证码页
      })
      .catch((err: Error): void => {
        this.submitting = false;
        this.errorText = `发送失败: ${err.message}`;
      });
  }

  build() {
    Column({ space: 16 }) {
      Text('登录 Telegram')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(AuthUi.TEXT_PRIMARY)
      Text('输入国际格式手机号（含国家代码），验证码将发送到你的 Telegram 已登录设备或短信。')
        .fontSize(13)
        .fontColor(AuthUi.TEXT_SECONDARY)
        .lineHeight(18)

      TextInput({ text: this.phoneText, placeholder: '例如 +86 138 0000 0000' })
        .type(InputType.PhoneNumber)
        .height(AuthUi.INPUT_HEIGHT)
        .backgroundColor(AuthUi.INPUT_BG)
        .fontColor(AuthUi.TEXT_PRIMARY)
        .enterKeyType(EnterKeyType.Done)
        .onSubmit((enterKey: EnterKeyType): void => {
          this.submit();
        })
        .onChange((value: string): void => {
          this.phoneText = value;
        })

      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(13).fontColor(AuthUi.TEXT_ERROR)
      }

      Button(this.submitting ? '发送中…' : '获取验证码')
        .width('100%')
        .height(44)
        .backgroundColor(this.submitting ? AuthUi.ACCENT_DISABLED : AuthUi.ACCENT)
        .enabled(!this.submitting)
        .onClick((): void => {
          this.submit();
        })

      Text('代理设置')
        .fontSize(13)
        .fontColor(AuthUi.ACCENT)
        .onClick((): void => {
          router.pushUrl({ url: 'pages/ProxyPage' });
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

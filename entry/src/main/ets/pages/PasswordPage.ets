/**
 * 两步验证密码页（M2）。提交后由 authState 驱动（ready → 主界面）。
 * 敏感信息：密码与 hint 不打日志。
 */
import { AuthService } from '../core/AuthService';
import { AuthUi } from './AuthUi';

@Entry
@Component
struct PasswordPage {
  @State passwordText: string = '';
  @State submitting: boolean = false;
  @State errorText: string = '';
  @State passwordHint: string = '';

  aboutToAppear(): void {
    // getRawState() 已是 authorizationState 内层对象（对齐 VerifyCode 修复）
    const state: Record<string, Object> = AuthService.getInstance().getRawState();
    const hintObj: Object | undefined = state['password_hint'];
    if (typeof hintObj === 'string' && (hintObj as string).length > 0) {
      this.passwordHint = `密码提示：${hintObj as string}`;
    }
  }

  private submit(): void {
    if (this.passwordText.length === 0) {
      this.errorText = '请输入两步验证密码';
      return;
    }
    this.submitting = true;
    this.errorText = '';
    AuthService.getInstance().requestPassword(this.passwordText)
      .then((): void => {
        this.submitting = false;
        // ready → Index 路由回主界面
      })
      .catch((err: Error): void => {
        this.submitting = false;
        this.errorText = `验证失败: ${err.message}`;
        this.passwordText = '';
      });
  }

  build() {
    Column({ space: 16 }) {
      Text('两步验证')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(AuthUi.TEXT_PRIMARY)
      if (this.passwordHint.length > 0) {
        Text(this.passwordHint).fontSize(13).fontColor(AuthUi.TEXT_SECONDARY)
      }

      TextInput({ text: this.passwordText, placeholder: '两步验证密码' })
        .type(InputType.Password)
        .height(AuthUi.INPUT_HEIGHT)
        .backgroundColor(AuthUi.INPUT_BG)
        .fontColor(AuthUi.TEXT_PRIMARY)
        .onChange((value: string): void => {
          this.passwordText = value;
        })

      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(13).fontColor(AuthUi.TEXT_ERROR)
      }

      Button(this.submitting ? '验证中…' : '验证密码')
        .width('100%')
        .height(44)
        .backgroundColor(this.submitting ? AuthUi.ACCENT_DISABLED : AuthUi.ACCENT)
        .enabled(!this.submitting)
        .onClick((): void => {
          this.submit();
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

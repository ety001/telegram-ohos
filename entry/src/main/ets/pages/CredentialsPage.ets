/**
 * 凭证输入页（M2）：api_id/api_hash 首启引导。
 * 凭证在 my.telegram.org/apps 申请，仅持久化到应用沙盒 preferences，永不入库。
 */
import { AuthService, AppAuthState, AuthStateObserver } from '../core/AuthService';
import { AuthUi } from './AuthUi';

@Entry
@Component
struct CredentialsPage {
  @State apiIdText: string = '';
  @State apiHashText: string = '';
  @State submitting: boolean = false;
  @State errorText: string = '';
  // 订阅凭证校验失败透传（setTdlibParameters 的 error 响应，M2 复审 CRITICAL 修复配套）
  private readonly authObserver: AuthStateObserver = (appState: string, raw: Record<string, Object>): void => {
    if (appState === AppAuthState.CREDENTIALS_ERROR) {
      this.submitting = false;
      this.errorText = `校验失败: ${AuthService.getInstance().lastCredentialsError}`;
    }
  };

  aboutToAppear(): void {
    AuthService.getInstance().onAuthState(this.authObserver);
  }

  aboutToDisappear(): void {
    AuthService.getInstance().offAuthState(this.authObserver);
  }

  private submit(): void {
    const apiId: number = Number.parseInt(this.apiIdText.trim());
    if (Number.isNaN(apiId) || apiId <= 0) {
      this.errorText = 'api_id 必须为正整数';
      return;
    }
    if (this.apiHashText.trim().length < 32) {
      this.errorText = 'api_hash 格式不正确（通常为 32 位十六进制）';
      return;
    }
    this.submitting = true;
    this.errorText = '';
    AuthService.getInstance().submitCredentials(apiId, this.apiHashText.trim())
      .then((): void => {
        this.submitting = false;
        // 参数已被 TDLib 接受，后续状态（waitPhoneNumber 等）由 Index 路由观察者接管；
        // 校验失败时 authObserver 会收到 CREDENTIALS_ERROR 并展示原因
      })
      .catch((err: Error): void => {
        this.submitting = false;
        this.errorText = `提交失败: ${err.message}`;
      });
  }

  build() {
    Column({ space: 16 }) {
      Text('Telegram API 凭证')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(AuthUi.TEXT_PRIMARY)
      Text('在 my.telegram.org/apps 登录并创建应用后，将获得的 api_id 与 api_hash 填入下方。凭证仅保存在本机应用沙盒。')
        .fontSize(13)
        .fontColor(AuthUi.TEXT_SECONDARY)
        .lineHeight(18)

      Column({ space: 8 }) {
        Text('api_id').fontSize(13).fontColor(AuthUi.TEXT_SECONDARY)
        TextInput({ text: this.apiIdText, placeholder: '例如 1234567' })
          .type(InputType.Number)
          .height(AuthUi.INPUT_HEIGHT)
          .backgroundColor(AuthUi.INPUT_BG)
          .fontColor(AuthUi.TEXT_PRIMARY)
          .onChange((value: string): void => {
            this.apiIdText = value;
          })

        Text('api_hash').fontSize(13).fontColor(AuthUi.TEXT_SECONDARY)
        TextInput({ text: this.apiHashText, placeholder: '32 位十六进制字符串' })
          .height(AuthUi.INPUT_HEIGHT)
          .backgroundColor(AuthUi.INPUT_BG)
          .fontColor(AuthUi.TEXT_PRIMARY)
          .onChange((value: string): void => {
            this.apiHashText = value;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(13).fontColor(AuthUi.TEXT_ERROR)
      }

      Button(this.submitting ? '提交中…' : '保存并继续')
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

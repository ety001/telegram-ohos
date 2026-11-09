/**
 * 验证码输入页（M2）。提交后由 authState 驱动跳转（waitPassword → 密码页 / ready → 主界面）。
 * 敏感信息：验证码不打日志。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AuthService } from '../core/AuthService';
import { AuthUi } from './AuthUi';

const TAG: string = 'VerifyCodePage';
const LOG_DOMAIN: number = 0x0012;

/** code_info.type 的 @type → 中文描述（简版映射） */
class CodeTypeText {
  static readonly TELEGRAM_MESSAGE: string = 'Telegram 消息';
  static readonly SMS: string = '短信';
  static readonly CALL: string = '电话语音';
  static readonly FLASH_CALL: string = '来显号码验证';
  static readonly MISSED_CALL: string = '未接来电';
  static readonly FRAGMENT: string = '分片验证码';
  static readonly OTHER: string = '其他方式';
}

@Entry
@Component
struct VerifyCodePage {
  @State codeText: string = '';
  @State submitting: boolean = false;
  @State errorText: string = '';
  @State codeTypeHint: string = '';

  aboutToAppear(): void {
    this.parseHint();
  }

  private parseHint(): void {
    // getRawState() 已是 authorizationState 内层对象（M2 复审 L2 修复：原多取一层致 hint 永不显示）
    const state: Record<string, Object> = AuthService.getInstance().getRawState();
    const infoObj: Object | undefined = state['code_info'];
    if (typeof infoObj !== 'object' || infoObj === null) {
      return;
    }
    const info = infoObj as Record<string, Object>;
    const typeObj: Object | undefined = info['type'];
    if (typeof typeObj !== 'object' || typeObj === null) {
      return;
    }
    const type = typeObj as Record<string, Object>;
    const tObj: Object | undefined = type['@type'];
    const t: string = typeof tObj === 'string' ? tObj as string : '';
    let hint: string = CodeTypeText.OTHER;
    if (t === 'authenticationCodeTypeTelegramMessage') {
      hint = CodeTypeText.TELEGRAM_MESSAGE;
    } else if (t === 'authenticationCodeTypeSms') {
      hint = CodeTypeText.SMS;
    } else if (t === 'authenticationCodeTypeCall') {
      hint = CodeTypeText.CALL;
    } else if (t === 'authenticationCodeTypeFlashCall') {
      hint = CodeTypeText.FLASH_CALL;
    } else if (t === 'authenticationCodeTypeMissedCall') {
      hint = CodeTypeText.MISSED_CALL;
    } else if (t === 'authenticationCodeTypeFragment') {
      hint = CodeTypeText.FRAGMENT;
    }
    this.codeTypeHint = `验证码已通过${hint}发送`;
    hilog.info(LOG_DOMAIN, TAG, 'code type: %{public}s', t);
  }

  private submit(): void {
    const code: string = this.codeText.replace(/[^0-9a-zA-Z]/g, '');
    if (code.length < 3) {
      this.errorText = '请输入完整验证码';
      return;
    }
    this.submitting = true;
    this.errorText = '';
    AuthService.getInstance().requestCode(code)
      .then((): void => {
        this.submitting = false;
        // ready → Index 路由回主界面；waitPassword → 密码页
      })
      .catch((err: Error): void => {
        this.submitting = false;
        this.errorText = `验证失败: ${err.message}`;
      });
  }

  private resend(): void {
    this.errorText = '';
    AuthService.getInstance().resendCode()
      .catch((err: Error): void => {
        this.errorText = `重发失败: ${err.message}`;
      });
  }

  build() {
    Column({ space: 16 }) {
      Text('输入验证码')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(AuthUi.TEXT_PRIMARY)
      if (this.codeTypeHint.length > 0) {
        Text(this.codeTypeHint).fontSize(13).fontColor(AuthUi.TEXT_SECONDARY)
      }

      TextInput({ text: this.codeText, placeholder: '验证码' })
        .type(InputType.Number)
        .height(AuthUi.INPUT_HEIGHT)
        .backgroundColor(AuthUi.INPUT_BG)
        .fontColor(AuthUi.TEXT_PRIMARY)
        .onChange((value: string): void => {
          this.codeText = value;
        })

      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(13).fontColor(AuthUi.TEXT_ERROR)
      }

      Button(this.submitting ? '验证中…' : '验证')
        .width('100%')
        .height(44)
        .backgroundColor(this.submitting ? AuthUi.ACCENT_DISABLED : AuthUi.ACCENT)
        .enabled(!this.submitting)
        .onClick((): void => {
          this.submit();
        })

      Text('重新发送验证码')
        .fontSize(13)
        .fontColor(AuthUi.ACCENT)
        .onClick((): void => {
          this.resend();
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

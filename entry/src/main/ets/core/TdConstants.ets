/**
 * TDLib TL 类型常量集中管理（M2）。
 * 所有 td_send/td_execute 的 @type 与更新流 @type 一律引用本文件，禁止散落魔法字符串。
 */
export class TdReq {
  static readonly SET_TDLIB_PARAMETERS: string = 'setTdlibParameters';
  static readonly SET_AUTHENTICATION_PHONE_NUMBER: string = 'setAuthenticationPhoneNumber';
  static readonly RESEND_AUTHENTICATION_CODE: string = 'resendAuthenticationCode';
  static readonly CHECK_AUTHENTICATION_CODE: string = 'checkAuthenticationCode';
  static readonly CHECK_AUTHENTICATION_PASSWORD: string = 'checkAuthenticationPassword';
  static readonly REQUEST_QR_CODE_AUTHENTICATION: string = 'requestQrCodeAuthentication';
  static readonly LOG_OUT: string = 'logOut';
  static readonly ADD_PROXY: string = 'addProxy';
  static readonly TEST_PROXY: string = 'testProxy';
  static readonly CLOSE: string = 'close';
  static readonly GET_VERSION: string = 'getVersion';
}

export class TdUpdate {
  static readonly AUTHORIZATION_STATE: string = 'updateAuthorizationState';
  static readonly OPTION: string = 'updateOption';
}

export class AuthStateType {
  static readonly WAIT_TDLIB_PARAMETERS: string = 'authorizationStateWaitTdlibParameters';
  static readonly WAIT_PHONE_NUMBER: string = 'authorizationStateWaitPhoneNumber';
  static readonly WAIT_CODE: string = 'authorizationStateWaitCode';
  static readonly WAIT_OTHER_DEVICE: string = 'authorizationStateWaitOtherDeviceConfirmation';
  static readonly WAIT_REGISTRATION: string = 'authorizationStateWaitRegistration';
  static readonly WAIT_EMAIL_ADDRESS: string = 'authorizationStateWaitEmailAddress';
  static readonly WAIT_EMAIL_CODE: string = 'authorizationStateWaitEmailCode';
  static readonly WAIT_PASSWORD: string = 'authorizationStateWaitPassword';
  static readonly READY: string = 'authorizationStateReady';
  static readonly LOGGING_OUT: string = 'authorizationStateLoggingOut';
  static readonly CLOSING: string = 'authorizationStateClosing';
  static readonly CLOSED: string = 'authorizationStateClosed';
}

export class ErrorType {
  static readonly INVALID: string = 'error';
}

/** TDLib 通用字段名 */
export class TdField {
  static readonly TYPE: string = '@type';
  static readonly EXTRA: string = '@extra';
  static readonly CLIENT_ID: string = '@client_id';
  static readonly MESSAGE: string = 'message';
  static readonly VERSION: string = 'version';
}

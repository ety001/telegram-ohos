/**
 * 登录状态机（M2）。
 *
 * 订阅 updateAuthorizationState 并封装为应用层 authState：
 * - credentialsMissing：收到 waitTdlibParameters 但本地无凭证（引导凭证页）
 * - credentialsError：setTdlibParameters 被拒（错误消息经 lastCredentialsError 透传凭证页）
 * - TDLib 1.8.63 原生状态原样透传（waitPhoneNumber/waitCode/waitPassword/ready/…）
 *
 * 状态驱动 UI：Index 作为唯一路由观察者负责登录流程页跳转；页面提交动作只调本类方法。
 * 所有登录动作 Promise 化：@extra 请求关联 + waitForExtra 超时/错误回传（页面据此展示错误）。
 * setTdlibParameters 走 sendAction：参数错误（api_hash 无效等）的 error 响应会带 @extra 回传，
 * 静默吞掉的路径已封死（M2 复审 CRITICAL 修复）。
 * 敏感信息（手机号/验证码/密码）一律不打日志。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { TdClient } from '../tdlib/TdClient';
import { TdUpdateRouter } from './TdUpdateRouter';
import { ConfigStore, ApiCredentials, ProxyConfig } from './ConfigStore';
import { TdReq, TdUpdate, AuthStateType, TdField, ErrorType } from './TdConstants';

const TAG: string = 'AuthService';
const LOG_DOMAIN: number = 0x0012;
const TEST_PROXY_EXTRA_PREFIX: string = 'testProxy';
const TEST_PROXY_TIMEOUT_MS: number = 20000;
const ACTION_TIMEOUT_MS: number = 15000;
/** 与 AppScope/app.json5 versionName 保持同步 */
const APP_VERSION: string = '0.2.0';

/** 应用层认证状态 */
export class AppAuthState {
  static readonly INITIAL: string = 'initial';
  static readonly CREDENTIALS_MISSING: string = 'credentialsMissing';
  static readonly CREDENTIALS_ERROR: string = 'credentialsError';
  static readonly TD_INITIALIZING: string = 'tdInitializing';
  static readonly WAIT_TDLIB_PARAMETERS: string = AuthStateType.WAIT_TDLIB_PARAMETERS;
  static readonly WAIT_PHONE_NUMBER: string = AuthStateType.WAIT_PHONE_NUMBER;
  static readonly WAIT_CODE: string = AuthStateType.WAIT_CODE;
  static readonly WAIT_OTHER_DEVICE: string = AuthStateType.WAIT_OTHER_DEVICE;
  static readonly WAIT_REGISTRATION: string = AuthStateType.WAIT_REGISTRATION;
  static readonly WAIT_EMAIL_ADDRESS: string = AuthStateType.WAIT_EMAIL_ADDRESS;
  static readonly WAIT_EMAIL_CODE: string = AuthStateType.WAIT_EMAIL_CODE;
  static readonly WAIT_PASSWORD: string = AuthStateType.WAIT_PASSWORD;
  static readonly READY: string = 'ready';
  static readonly LOGGING_OUT: string = AuthStateType.LOGGING_OUT;
  static readonly CLOSED: string = AuthStateType.CLOSED;
}

export type AuthStateObserver = (appState: string, rawState: Record<string, Object>) => void;

interface ExtraWaiter {
  extra: string;
  resolve: (update: Record<string, Object>) => void;
  reject: (reason: string) => void;
  timerId: number;
}

export class AuthService {
  private static instance: AuthService | null = null;

  private appState: string = AppAuthState.INITIAL;
  private currentRawState: Record<string, Object> = {};
  private observers: Array<AuthStateObserver> = [];
  private started: boolean = false;
  private actionSeq: number = 0;
  private actionWaiters: Map<string, ExtraWaiter> = new Map();
  /** 最近一次凭证应用失败的原因（CredentialsPage 展示用；成功时清空） */
  lastCredentialsError: string = '';

  private constructor() {
  }

  static getInstance(): AuthService {
    if (AuthService.instance === null) {
      AuthService.instance = new AuthService();
    }
    return AuthService.instance;
  }

  /** 订阅路由并开始接收 authorizationState 更新（幂等） */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    TdClient.getInstance().start();
    TdUpdateRouter.getInstance().register(TdUpdate.AUTHORIZATION_STATE,
      (update: Record<string, Object>): void => {
        this.handleAuthStateUpdate(update);
      });
    TdUpdateRouter.getInstance().registerFallback((update: Record<string, Object>): void => {
      this.dispatchActionReply(update);
    });
    hilog.info(LOG_DOMAIN, TAG, 'AuthService started');
  }

  /** 订阅应用层认证状态变化（订阅即推送当前状态） */
  onAuthState(observer: AuthStateObserver): void {
    if (!this.observers.includes(observer)) {
      this.observers.push(observer);
    }
    observer(this.appState, this.currentRawState);
  }

  offAuthState(observer: AuthStateObserver): void {
    const index: number = this.observers.indexOf(observer);
    if (index >= 0) {
      this.observers.splice(index, 1);
    }
  }

  getAuthState(): string {
    return this.appState;
  }

  getRawState(): Record<string, Object> {
    return this.currentRawState;
  }

  private setState(appState: string, rawState: Record<string, Object>): void {
    this.appState = appState;
    this.currentRawState = rawState;
    for (const observer of this.observers) {
      try {
        observer(appState, rawState);
      } catch (err) {
        hilog.error(LOG_DOMAIN, TAG, 'authState observer error: %{private}s', JSON.stringify(err));
      }
    }
  }

  private handleAuthStateUpdate(update: Record<string, Object>): void {
    const stateObj: Object | undefined = update['authorization_state'];
    if (typeof stateObj !== 'object' || stateObj === null) {
      return;
    }
    const state = stateObj as Record<string, Object>;
    const typeObj: Object | undefined = state[TdField.TYPE];
    const type: string = typeof typeObj === 'string' ? typeObj as string : '';
    hilog.info(LOG_DOMAIN, TAG, 'authorizationState -> %{public}s', type);

    // TDLib 1.8.63 AuthorizationState 全集（td_api.tl 核对）：13 态，无 waitEncryptionKey
    switch (type) {
      case AuthStateType.WAIT_TDLIB_PARAMETERS:
        this.handleWaitTdlibParameters(state);
        break;
      case AuthStateType.WAIT_PHONE_NUMBER:
        this.setState(AppAuthState.WAIT_PHONE_NUMBER, state);
        break;
      case AuthStateType.WAIT_CODE:
        this.setState(AppAuthState.WAIT_CODE, state);
        break;
      case AuthStateType.WAIT_OTHER_DEVICE:
        this.setState(AppAuthState.WAIT_OTHER_DEVICE, state);
        break;
      case AuthStateType.WAIT_REGISTRATION:
        this.setState(AppAuthState.WAIT_REGISTRATION, state);
        break;
      case AuthStateType.WAIT_EMAIL_ADDRESS:
        this.setState(AppAuthState.WAIT_EMAIL_ADDRESS, state);
        break;
      case AuthStateType.WAIT_EMAIL_CODE:
        this.setState(AppAuthState.WAIT_EMAIL_CODE, state);
        break;
      case AuthStateType.WAIT_PASSWORD:
        this.setState(AppAuthState.WAIT_PASSWORD, state);
        break;
      case AuthStateType.READY:
        this.setState(AppAuthState.READY, state);
        break;
      case AuthStateType.LOGGING_OUT:
        this.setState(AppAuthState.LOGGING_OUT, state);
        break;
      case AuthStateType.CLOSING:
        break;
      case AuthStateType.CLOSED:
        this.setState(AppAuthState.CLOSED, state);
        break;
      default:
        this.setState(type, state);
        break;
    }
  }

  /** waitTdlibParameters：读凭证自动补参；无凭证/读取失败则引导凭证页 */
  private handleWaitTdlibParameters(state: Record<string, Object>): void {
    this.setState(AppAuthState.WAIT_TDLIB_PARAMETERS, state);
    ConfigStore.getCredentials().then((cred: ApiCredentials | null): void => {
      if (cred === null) {
        this.setState(AppAuthState.CREDENTIALS_MISSING, state);
        return;
      }
      this.applyTdlibParameters(cred);
    }).catch((err: Error): void => {
      hilog.error(LOG_DOMAIN, TAG, 'read credentials failed: %{private}s', err.message);
      this.lastCredentialsError = err.message;
      this.setState(AppAuthState.CREDENTIALS_ERROR, state);
    });
  }

  /**
   * 用给定凭证发送 setTdlibParameters（凭证页提交后也走这里）。
   * 走 sendAction：参数/DB 错误的 error 响应（带 @extra）会被捕获并透传给凭证页，
   * 成功后由状态机推进（waitPhoneNumber 等），本 Promise 仅表达"请求被接受"。
   */
  applyTdlibParameters(cred: ApiCredentials): Promise<void> {
    this.setState(AppAuthState.TD_INITIALIZING, this.currentRawState);
    const filesDir: string = ConfigStore.getFilesDir();
    const params: Record<string, Object> = {
      ['@type']: TdReq.SET_TDLIB_PARAMETERS,
      'api_id': cred.apiId,
      'api_hash': cred.apiHash,
      // 沙盒绝对路径（M2 复审 HIGH：相对路径相对进程 cwd 解析，违反沙盒原则）
      'database_directory': `${filesDir}/tdlib/db`,
      'files_directory': `${filesDir}/tdlib/files`,
      'database_encryption_key': '',
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': true,
      // 1.8.63 必填非空字段（缺省空串直接 400，M2 复审 CRITICAL 修复）
      'system_language_code': 'zh-Hans',
      'device_model': `${deviceInfo.productModel}`,
      'system_version': '',
      'application_version': APP_VERSION
    };
    return this.sendAction(params, 'setParams').then((): void => {
      // 请求被接受；后续由状态机推进（waitPhoneNumber 等）
    }).catch((reason: string): void => {
      hilog.warn(LOG_DOMAIN, TAG, 'setTdlibParameters rejected: %{private}s', reason);
      this.lastCredentialsError = reason;
      this.setState(AppAuthState.CREDENTIALS_ERROR, this.currentRawState);
    });
  }

  /** 凭证页提交：持久化 + 应用参数（错误经 lastCredentialsError 透传） */
  submitCredentials(apiId: number, apiHash: string): Promise<void> {
    return ConfigStore.putCredentials(apiId, apiHash).then((): Promise<void> => {
      const cred: ApiCredentials = { apiId: apiId, apiHash: apiHash };
      return this.applyTdlibParameters(cred);
    });
  }

  /** 登录：手机号（国际格式，如 8613800000000）。1.8.63 仅必填 phone_number */
  requestPhoneNumber(phone: string): Promise<Record<string, Object>> {
    // 敏感信息：手机号不打日志
    return this.sendAction({
      ['@type']: TdReq.SET_AUTHENTICATION_PHONE_NUMBER,
      'phone_number': phone
    }, 'phone');
  }

  resendCode(): Promise<Record<string, Object>> {
    return this.sendAction({ ['@type']: TdReq.RESEND_AUTHENTICATION_CODE }, 'resend');
  }

  requestCode(code: string): Promise<Record<string, Object>> {
    return this.sendAction({
      ['@type']: TdReq.CHECK_AUTHENTICATION_CODE,
      'code': code
    }, 'code');
  }

  requestPassword(password: string): Promise<Record<string, Object>> {
    return this.sendAction({
      ['@type']: TdReq.CHECK_AUTHENTICATION_PASSWORD,
      'password': password
    }, 'password');
  }

  applyProxy(config: ProxyConfig): Promise<Record<string, Object>> {
    this.actionSeq += 1;
    return this.sendAction(this.proxyRequest(config, TdReq.ADD_PROXY, config.enable,
      `addProxy_${this.actionSeq}`), 'addProxy');
  }

  testProxy(config: ProxyConfig): Promise<Record<string, Object>> {
    // extra 带序号：避免超时后重测被迟到旧回复误 resolve（M2 复审 LOW 修复）
    this.actionSeq += 1;
    const extra: string = `${TEST_PROXY_EXTRA_PREFIX}_${this.actionSeq}`;
    const waiter: Promise<Record<string, Object>> =
      TdUpdateRouter.getInstance().waitForExtra(extra, TEST_PROXY_TIMEOUT_MS);
    const req: Record<string, Object> = this.proxyRequest(config, TdReq.TEST_PROXY, false, extra);
    TdClient.getInstance().send(req);
    return waiter.then((update: Record<string, Object>): Record<string, Object> => {
      const typeObj: Object | undefined = update[TdField.TYPE];
      const type: string = typeof typeObj === 'string' ? typeObj as string : '';
      if (type === ErrorType.INVALID) {
        const msgObj: Object | undefined = update[TdField.MESSAGE];
        throw new Error(typeof msgObj === 'string' ? msgObj as string : 'proxy test failed');
      }
      return update;
    });
  }

  // 1.8.63 schema：addProxy proxy:proxy enable:Bool；testProxy proxy:proxy dc_id:int32 timeout:double
  // （M2 复审 HIGH 修复：旧平铺 server/port/type 字段已被 TDLib 忽略，代理整体不可用）
  private proxyRequest(config: ProxyConfig, reqType: string, enable: boolean,
    extra: string): Record<string, Object> {
    const typeObj: Record<string, Object> = config.proxyType === 'mtproto'
      ? { '@type': 'proxyTypeMtproto', 'secret': config.password }
      : { '@type': 'proxyTypeSocks5', 'username': config.user, 'password': config.password };
    const proxy: Record<string, Object> = {
      ['@type']: 'proxy',
      'server': config.host,
      'port': config.port,
      'type': typeObj
    };
    const req: Record<string, Object> = {
      ['@type']: reqType,
      'proxy': proxy,
      'enable': enable
    };
    if (reqType === TdReq.TEST_PROXY) {
      // 生产 DC 仅 1-5（dc_id=0 会 400 Invalid datacenter）；2 为主 DC
      req['dc_id'] = 2;
      req['timeout'] = 15;
      req[TdField.EXTRA] = extra;
    }
    return req;
  }

  logOut(): void {
    TdClient.getInstance().send({ ['@type']: TdReq.LOG_OUT });
  }

  /** 动作基元：send + @extra + 等待直接回复（error 响应 reject 并透传 message） */
  private sendAction(request: Record<string, Object>, extraKey: string): Promise<Record<string, Object>> {
    this.actionSeq += 1;
    const extra: string = `${extraKey}_${this.actionSeq}`;
    const full: Record<string, Object> = request;
    full[TdField.EXTRA] = extra;
    const waiterPromise: Promise<Record<string, Object>> = new Promise<Record<string, Object>>(
      (resolve: (v: Record<string, Object>) => void, reject: (r: string) => void): void => {
        const timerId: number = setTimeout((): void => {
          this.actionWaiters.delete(extra);
          reject(`${extraKey} timeout`);
        }, ACTION_TIMEOUT_MS);
        const waiter: ExtraWaiter = { extra: extra, resolve: resolve, reject: reject, timerId: timerId };
        this.actionWaiters.set(extra, waiter);
      });
    TdClient.getInstance().send(full);
    // error 回复由 dispatchActionReply 统一 reject；成功回复（ok 等）直接 resolve
    return waiterPromise;
  }

  private dispatchActionReply(update: Record<string, Object>): void {
    const extraObj: Object | undefined = update[TdField.EXTRA];
    if (typeof extraObj !== 'string') {
      return;
    }
    const extra: string = extraObj as string;
    const waiter: ExtraWaiter | undefined = this.actionWaiters.get(extra);
    if (waiter === undefined) {
      return;
    }
    this.actionWaiters.delete(extra);
    clearTimeout(waiter.timerId);
    const typeObj: Object | undefined = update[TdField.TYPE];
    const type: string = typeof typeObj === 'string' ? typeObj as string : '';
    if (type === ErrorType.INVALID) {
      const msgObj: Object | undefined = update[TdField.MESSAGE];
      const msg: string = typeof msgObj === 'string' ? msgObj as string : 'request failed';
      hilog.warn(LOG_DOMAIN, TAG, 'action rejected: %{private}s', msg);
      waiter.reject(msg);
      return;
    }
    waiter.resolve(update);
  }
}

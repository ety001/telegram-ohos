/**
 * 应用配置存储（M2）：基于 @ohos.data.preferences 的持久化封装。
 *
 * 承载三类不入库（AGENTS.md 红线）的运行时配置：
 * - Telegram API 凭证（my.telegram.org/apps 申请的 api_id/api_hash）
 * - 代理配置（国内登录 DC 硬前置）
 * - 应用沙盒路径缓存（TDLib 数据库目录须用绝对路径，M2 复审修复）
 *
 * 异步初始化门闩：preferences 打开是异步 I/O，所有访问器先 await ready()
 * 避免"init fire-and-forget 后立即读取"的冷启动竞态（M2 复审 HIGH 修复）。
 */
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const PREF_NAME: string = 'telegram_ohos_config';
const KEY_API_ID: string = 'api_id';
const KEY_API_HASH: string = 'api_hash';
const KEY_PROXY_HOST: string = 'proxy_host';
const KEY_PROXY_PORT: string = 'proxy_port';
const KEY_PROXY_USER: string = 'proxy_user';
const KEY_PROXY_PASSWORD: string = 'proxy_password';
const KEY_PROXY_TYPE: string = 'proxy_type';
const KEY_PROXY_ENABLE: string = 'proxy_enable';
/** 通知预览开关（M6-8） */
const KEY_NOTIFY_PREVIEW: string = 'notify_preview';

/** Telegram API 凭证（my.telegram.org/apps 申请） */
export interface ApiCredentials {
  apiId: number;
  apiHash: string;
}

/** 代理配置；proxyType: 'socks5' | 'mtproto' */
export interface ProxyConfig {
  host: string;
  port: number;
  user: string;
  password: string;
  proxyType: string;
  enable: boolean;
}

export class ConfigStore {
  private static store: preferences.Preferences | null = null;
  private static readyPromise: Promise<void> | null = null;
  private static appFilesDir: string = '';

  /** 在 EntryAbility.onCreate 调用；所有访问器内部先 await ready() */
  static init(context: Context): void {
    if (ConfigStore.readyPromise !== null) {
      return;
    }
    ConfigStore.appFilesDir = context.filesDir;
    ConfigStore.readyPromise = preferences.getPreferences(context, PREF_NAME)
      .then((store: preferences.Preferences): void => {
        ConfigStore.store = store;
      })
      .catch((err: BusinessError): void => {
        ConfigStore.readyPromise = null;
        throw new Error(`ConfigStore init failed: ${err.message}`);
      });
  }

  /** 初始化门闩：preferences 就绪后 resolve；未 init 则 reject（调用链可给用户反馈） */
  static ready(): Promise<void> {
    if (ConfigStore.readyPromise === null) {
      return Promise.reject('ConfigStore not initialized: call init(context) first');
    }
    return ConfigStore.readyPromise;
  }

  /** 应用沙盒 files 绝对路径（init 后可用；TDLib 数据库/文件目录必须以此拼绝对路径） */
  static getFilesDir(): string {
    return ConfigStore.appFilesDir;
  }

  private static async requireStore(): Promise<preferences.Preferences> {
    await ConfigStore.ready();
    return ConfigStore.store as preferences.Preferences;
  }

  static async hasCredentials(): Promise<boolean> {
    const store: preferences.Preferences = await ConfigStore.requireStore();
    const apiId: number = (await store.get(KEY_API_ID, 0)) as number;
    const apiHash: string = (await store.get(KEY_API_HASH, '')) as string;
    return apiId > 0 && apiHash.length > 0;
  }

  static async getCredentials(): Promise<ApiCredentials | null> {
    const store: preferences.Preferences = await ConfigStore.requireStore();
    const apiId: number = (await store.get(KEY_API_ID, 0)) as number;
    const apiHash: string = (await store.get(KEY_API_HASH, '')) as string;
    if (apiId <= 0 || apiHash.length === 0) {
      return null;
    }
    const cred: ApiCredentials = { apiId: apiId, apiHash: apiHash };
    return cred;
  }

  static async putCredentials(apiId: number, apiHash: string): Promise<void> {
    const store: preferences.Preferences = await ConfigStore.requireStore();
    await store.put(KEY_API_ID, apiId);
    await store.put(KEY_API_HASH, apiHash);
    await store.flush();
  }

  static async getProxy(): Promise<ProxyConfig | null> {
    const store: preferences.Preferences = await ConfigStore.requireStore();
    const host: string = (await store.get(KEY_PROXY_HOST, '')) as string;
    if (host.length === 0) {
      return null;
    }
    const config: ProxyConfig = {
      host: host,
      port: (await store.get(KEY_PROXY_PORT, 1080)) as number,
      user: (await store.get(KEY_PROXY_USER, '')) as string,
      password: (await store.get(KEY_PROXY_PASSWORD, '')) as string,
      proxyType: (await store.get(KEY_PROXY_TYPE, 'socks5')) as string,
      enable: (await store.get(KEY_PROXY_ENABLE, false)) as boolean
    };
    return config;
  }

  static async putProxy(config: ProxyConfig): Promise<void> {
    const store: preferences.Preferences = await ConfigStore.requireStore();
    await store.put(KEY_PROXY_HOST, config.host);
    await store.put(KEY_PROXY_PORT, config.port);
    await store.put(KEY_PROXY_USER, config.user);
    await store.put(KEY_PROXY_PASSWORD, config.password);
    await store.put(KEY_PROXY_TYPE, config.proxyType);
    await store.put(KEY_PROXY_ENABLE, config.enable);
    await store.flush();
  }

  // ---------------- 偏好设置（M6-8） ----------------

  /** 通知预览开关（默认开：通知正文显示消息内容；关：仅「你有一条新消息」不泄露内容） */
  static async getNotifyPreview(): Promise<boolean> {
    const store: preferences.Preferences = await ConfigStore.requireStore();
    return (await store.get(KEY_NOTIFY_PREVIEW, true)) as boolean;
  }

  static async putNotifyPreview(enable: boolean): Promise<void> {
    const store: preferences.Preferences = await ConfigStore.requireStore();
    await store.put(KEY_NOTIFY_PREVIEW, enable);
    await store.flush();
  }
}

/**
 * 本地草稿仓库（M6-1）。单例。内存态。
 *
 * 背景（1.8.63 schema 审计结论，见 tmp/telegram-ohos-m6-gap-plan.md §4.1）：
 * TDLib 1.8.63 无 saveDraft/clearDraft 公开函数（上游已移除），客户端无法写云端草稿；
 * 云端草稿只能读（updateChatDraftMessage / chat.draft_message）与清（发送时
 * inputMessageText.clear_draft=true）。本地切换会话的输入内容因此由本仓库内存保存：
 * - ChatPanel 切会话（switchChat）/组件销毁时保存旧会话输入文本；
 * - 激活会话时恢复到输入框；发送成功即清除；
 * - 登出（reset）全清。
 *
 * 不持久化（重启即失）为 v1 取舍：草稿价值集中在单次使用会话内，跨重启恢复登记 M7。
 * 会话列表行显示优先级：本地草稿（红「草稿」）> 云端草稿（灰「草稿」）> last_message 预览
 * （云端草稿读取在 ChatUi.buildRow，本仓库只管本地侧）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'DraftStore';
const LOG_DOMAIN: number = 0x0012;

export type DraftObserver = () => void;

export class DraftStore {
  private static instance: DraftStore | null = null;

  private drafts: Map<number, string> = new Map();
  private observers: Array<DraftObserver> = [];

  private constructor() {
  }

  static getInstance(): DraftStore {
    if (DraftStore.instance === null) {
      DraftStore.instance = new DraftStore();
    }
    return DraftStore.instance;
  }

  /** 保存草稿：空文本等价清除 */
  save(chatId: number, text: string): void {
    if (chatId === 0) {
      return;
    }
    const trimmed: string = text.trim();
    const existed: boolean = this.drafts.has(chatId);
    if (trimmed.length === 0) {
      if (existed) {
        this.drafts.delete(chatId);
        this.notifyChanged();
      }
      return;
    }
    const current: string | undefined = this.drafts.get(chatId);
    if (current === trimmed) {
      return;
    }
    this.drafts.set(chatId, trimmed);
    this.notifyChanged();
  }

  /** 恢复草稿到输入框：无草稿返回空串 */
  restore(chatId: number): string {
    const text: string | undefined = this.drafts.get(chatId);
    return text === undefined ? '' : text;
  }

  /** 发送成功后清除（含云端语义由 sendText 的 clear_draft 承担，这里只清本地） */
  clear(chatId: number): void {
    if (this.drafts.delete(chatId)) {
      this.notifyChanged();
    }
  }

  /** 本地草稿预览文本（会话列表行用；无草稿返回空串） */
  draftOf(chatId: number): string {
    const text: string | undefined = this.drafts.get(chatId);
    return text === undefined ? '' : text;
  }

  /** 登出全清 */
  reset(): void {
    if (this.drafts.size === 0) {
      return;
    }
    this.drafts.clear();
    this.notifyChanged();
    hilog.info(LOG_DOMAIN, TAG, 'reset');
  }

  addObserver(observer: DraftObserver): void {
    if (!this.observers.includes(observer)) {
      this.observers.push(observer);
    }
  }

  removeObserver(observer: DraftObserver): void {
    const index: number = this.observers.indexOf(observer);
    if (index >= 0) {
      this.observers.splice(index, 1);
    }
  }

  private notifyChanged(): void {
    for (const observer of this.observers) {
      try {
        observer();
      } catch (err) {
        hilog.error(LOG_DOMAIN, TAG, 'observer error: %{private}s', JSON.stringify(err));
      }
    }
  }
}

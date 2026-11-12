/**
 * 会话列表 LazyForEach 数据源（M2）。
 *
 * 选型说明（LazyForEach vs For）：千级会话列表选 LazyForEach——按需仅为可见行创建组件、
 * 滚出屏即销毁，内存与首帧开销远低于 ForEach（后者一次性创建全部行组件常驻）。
 * 简版实现：任意数据变更整体 onDataReloaded（仅重建可见行，n 次变更 O(可见行数)）；
 * 精细化 onDataMove/onDataChange 增量刷新留待列表性能实测后再做。
 *
 * 搜索（M2 简版）：对已加载会话做标题本地过滤（contains，忽略大小写）。
 * 后续接服务端搜索：TDLib 实际有通用 searchChats（离线搜全部已知会话，含尚未加载进 UI 的）、
 * 以及 searchChatsOnServer / searchPublicChat(公开会话/频道)——归入 M5「会话搜索」任务。
 */
import { ChatListStore, ChatListObserver } from '../core/ChatListStore';
import { DraftStore, DraftObserver } from '../core/DraftStore';
import { ChatRowModel, ChatUi } from './ChatUi';

export class ChatListDataSource implements IDataSource {
  private listeners: Array<DataChangeListener> = [];
  private visibleIds: Array<number> = [];
  private keyword: string = '';
  private readonly storeObserver: ChatListObserver = (): void => {
    this.rebuild();
    this.notifyReload();
  };
  // 本地草稿变化（M6-1）：行预览含草稿前缀，DraftStore 通知同样触发可见行重建
  private readonly draftObserver: DraftObserver = (): void => {
    this.rebuild();
    this.notifyReload();
  };

  constructor() {
    ChatListStore.getInstance().addObserver(this.storeObserver);
    DraftStore.getInstance().addObserver(this.draftObserver);
    this.rebuild();
  }

  /** 页面 aboutToDisappear 注销，防泄漏 */
  dispose(): void {
    ChatListStore.getInstance().removeObserver(this.storeObserver);
    DraftStore.getInstance().removeObserver(this.draftObserver);
  }

  setKeyword(keyword: string): void {
    const trimmed: string = keyword.trim().toLowerCase();
    if (trimmed === this.keyword) {
      return;
    }
    this.keyword = trimmed;
    this.rebuild();
    this.notifyReload();
  }

  getKeyword(): string {
    return this.keyword;
  }

  totalCount(): number {
    return this.visibleIds.length;
  }

  getData(index: number): ChatRowModel {
    if (index < 0 || index >= this.visibleIds.length) {
      return new ChatRowModel(); // 越界防御（reload 与可见行重建的竞态窗口）
    }
    const chat: Record<string, Object> | undefined =
      ChatListStore.getInstance().getChat(this.visibleIds[index]);
    if (chat === undefined) {
      return new ChatRowModel();
    }
    return ChatUi.buildRow(chat);
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** 关键字过滤（标题 contains）作用于仓库有序列表的快照副本 */
  private rebuild(): void {
    const store: ChatListStore = ChatListStore.getInstance();
    const ids: Array<number> = [];
    for (const chatId of store.getOrderedIds()) {
      if (this.keyword.length === 0) {
        ids.push(chatId);
        continue;
      }
      const title: string = store.getTitle(chatId).toLowerCase();
      if (title.indexOf(this.keyword) >= 0) {
        ids.push(chatId);
      }
    }
    this.visibleIds = ids;
  }

  private notifyReload(): void {
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

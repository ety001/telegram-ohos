/**
 * 时间格式化（M2 会话列表 / M3 消息流共享，自写实现）。
 *
 * 规则（本地时区）：
 * - 会话列表：今天 → HH:mm（24 小时制，两位补零）/ 昨天 →「昨天」/ 今年更早 → M月d日 / 跨年 → yyyy/M/d
 * - 消息流按天分组头：今天 →「今天」/ 昨天 →「昨天」/ 最近 7 天 →「星期X」/ 今年 → M月d日 / 跨年 → yyyy年M月d日
 * - 消息气泡内：HH:mm
 *
 * 说明：跨天滚动（列表停留至次日零点）不主动刷新，下一次数据变更时自然重算（M2/M3 取舍）。
 */
export class TimeFormat {
  private static readonly MS_PER_DAY: number = 24 * 60 * 60 * 1000;
  private static readonly WEEKDAY_LABELS: Array<string> =
    ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];

  /** unix 秒 → 列表时间文案；非法时间（<=0）返回空串 */
  static formatChatListTime(unixSeconds: number, nowMs: number): string {
    if (!TimeFormat.isValid(unixSeconds)) {
      return '';
    }
    const date: Date = new Date(unixSeconds * 1000);
    if (date.getTime() > nowMs + TimeFormat.MS_PER_DAY) {
      return '';
    }
    const now: Date = new Date(nowMs);
    const dayDiff: number = TimeFormat.dayDiff(date, now);
    if (dayDiff === 0) {
      return TimeFormat.formatTime(unixSeconds);
    }
    if (dayDiff === 1) {
      return '昨天';
    }
    if (date.getFullYear() === now.getFullYear()) {
      return `${date.getMonth() + 1}月${date.getDate()}日`;
    }
    return `${date.getFullYear()}/${date.getMonth() + 1}/${date.getDate()}`;
  }

  /** unix 秒 → 消息流按天分组头（今天/昨天/最近 7 天星期/日期）；非法时间（<=0）返回空串 */
  static formatDayLabel(unixSeconds: number, nowMs: number): string {
    if (!TimeFormat.isValid(unixSeconds)) {
      return '';
    }
    const date: Date = new Date(unixSeconds * 1000);
    if (date.getTime() > nowMs + TimeFormat.MS_PER_DAY) {
      return '';
    }
    const now: Date = new Date(nowMs);
    const dayDiff: number = TimeFormat.dayDiff(date, now);
    if (dayDiff === 0) {
      return '今天';
    }
    if (dayDiff === 1) {
      return '昨天';
    }
    // 未来/更早日志异常数据兜底：dayDiff 为负按 0~1 天之外的分支处理，最多显示星期
    if (dayDiff > 0 && dayDiff < 7) {
      return TimeFormat.WEEKDAY_LABELS[date.getDay()];
    }
    if (date.getFullYear() === now.getFullYear()) {
      return `${date.getMonth() + 1}月${date.getDate()}日`;
    }
    return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
  }

  /** unix 秒 → 气泡内时间（HH:mm，24 小时制，两位补零）；非法时间返回空串 */
  static formatTime(unixSeconds: number): string {
    if (!TimeFormat.isValid(unixSeconds)) {
      return '';
    }
    const date: Date = new Date(unixSeconds * 1000);
    return `${TimeFormat.pad2(date.getHours())}:${TimeFormat.pad2(date.getMinutes())}`;
  }

  /** 消息所属「天」的 key（当天零点毫秒，同天消息共用一个分组头） */
  static dayKeyOf(unixSeconds: number): number {
    if (!TimeFormat.isValid(unixSeconds)) {
      return 0;
    }
    return TimeFormat.dayStart(new Date(unixSeconds * 1000));
  }

  private static isValid(unixSeconds: number): boolean {
    return Number.isFinite(unixSeconds) && unixSeconds > 0;
  }

  /** date 相对 now 的整天差（now 的前一天为 1；本地时区口径） */
  private static dayDiff(date: Date, now: Date): number {
    const dayStart: number = TimeFormat.dayStart(date);
    const nowDayStart: number = TimeFormat.dayStart(now);
    return Math.round((nowDayStart - dayStart) / TimeFormat.MS_PER_DAY);
  }

  /** 当天零点的时间戳（本地时区） */
  private static dayStart(date: Date): number {
    const start: Date = new Date(date.getFullYear(), date.getMonth(), date.getDate());
    return start.getTime();
  }

  private static pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }
}

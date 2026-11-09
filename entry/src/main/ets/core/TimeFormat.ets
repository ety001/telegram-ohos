/**
 * 会话列表相对时间格式化（M2，自写实现）。
 *
 * 规则（本地时区）：
 * - 今天 → HH:mm（24 小时制，两位补零）
 * - 昨天 → 固定文案「昨天」
 * - 今年更早 → M月d日
 * - 跨年 → yyyy/M/d
 *
 * 说明：跨天滚动（列表停留至次日零点）不主动刷新，下一次列表数据变更时自然重算（M2 取舍）。
 */
export class TimeFormat {
  private static readonly MS_PER_DAY: number = 24 * 60 * 60 * 1000;

  /** unix 秒 → 列表时间文案；非法时间（<=0）返回空串 */
  static formatChatListTime(unixSeconds: number, nowMs: number): string {
    if (!Number.isFinite(unixSeconds) || unixSeconds <= 0) {
      return '';
    }
    const date: Date = new Date(unixSeconds * 1000);
    if (date.getTime() > nowMs + TimeFormat.MS_PER_DAY) {
      return '';
    }
    const now: Date = new Date(nowMs);
    const dayStart: number = TimeFormat.dayStart(date);
    const nowDayStart: number = TimeFormat.dayStart(now);
    const dayDiff: number = Math.round((nowDayStart - dayStart) / TimeFormat.MS_PER_DAY);
    if (dayDiff === 0) {
      return `${TimeFormat.pad2(date.getHours())}:${TimeFormat.pad2(date.getMinutes())}`;
    }
    if (dayDiff === 1) {
      return '昨天';
    }
    if (date.getFullYear() === now.getFullYear()) {
      return `${date.getMonth() + 1}月${date.getDate()}日`;
    }
    return `${date.getFullYear()}/${date.getMonth() + 1}/${date.getDate()}`;
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

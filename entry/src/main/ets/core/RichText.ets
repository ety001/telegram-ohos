/**
 * 富文本解析（M5）：TDLib formattedText { text, entities } → 样式切片序列。
 *
 * TL 契约（1.8.63 td_api.tl@f06b0bac 官方注释原文核对）：
 * - textEntity 注释明确 "offset/length in **UTF-16 code units**"；
 * - ArkTS/JS 字符串的索引与 substring 同为 UTF-16 code unit——单位天然一致，
 *   直接按下标切分即可，无需码点换算（换算反而会引入越界错位）；
 * - entities 可嵌套但不相交：同一片段可被多个 entity 完整覆盖（样式叠加）。
 *
 * 实现为纯函数式数据投影（不改 TDLib 原对象），防御策略：
 * - offset/length 越界（负值 / 超长）钳制到 [0, text.length]，零长度 entity 丢弃；
 * - 相邻同样式片段合并（减少 Span 数量）；
 * - 未识别的 entity 类型按普通文本处理（custom_emoji/spoiler/block_quote 等，见 TdTextEntityType 注释）。
 *
 * 日志红线：本模块不产生日志（text/url 属消息内容）。
 */
import { TdField, TdTextEntityType } from './TdConstants';

/** 富文本切片：一段纯文本 + 该段叠加后的样式标记 */
export class RichSegment {
  text: string = '';
  bold: boolean = false;
  italic: boolean = false;
  underline: boolean = false;
  strikethrough: boolean = false;
  /** code/pre/preCode：等宽字体呈现 */
  code: boolean = false;
  /** 链接色（含 mention/hashtag 等暂不可点击类） */
  link: boolean = false;
  /** 可点击打开的完整 URL（textUrl.url / 原文 URL entity 的文本本身）；空串 = 不可点击 */
  url: string = '';

  /** 无任何样式（与纯文本等价，视图可走原 Text 路径） */
  isPlain(): boolean {
    return !this.bold && !this.italic && !this.underline && !this.strikethrough &&
      !this.code && !this.link && this.url.length === 0;
  }
}

/** 内部中间结构：钳制后的 entity 区间（半开区间 [start, end)，单位 UTF-16 code unit） */
interface EntityRange {
  start: number;
  end: number;
  type: string;
  url: string;
}

export class RichText {
  /**
   * formattedText → 样式切片序列。
   * 返回空数组 = 无可渲染内容（空文本 / 缺 entities 的纯文本由调用方按原路径处理）；
   * entities 为空数组时返回单个普通切片。
   */
  static parse(formatted: Record<string, Object> | null): Array<RichSegment> {
    if (formatted === null) {
      return [];
    }
    const text: string = RichText.readString(formatted, TdField.TEXT);
    if (text.length === 0) {
      return [];
    }
    const ranges: Array<EntityRange> = RichText.collectRanges(formatted, text);
    if (ranges.length === 0) {
      const plain: RichSegment = new RichSegment();
      plain.text = text;
      return [plain];
    }

    // 切点集合：{0, text.length} ∪ 各 entity 边界，升序去重
    const bounds: Array<number> = [0, text.length];
    for (const range of ranges) {
      bounds.push(range.start);
      bounds.push(range.end);
    }
    bounds.sort((a: number, b: number): number => a - b);

    const segments: Array<RichSegment> = [];
    for (let i: number = 0; i < bounds.length - 1; i++) {
      const start: number = bounds[i];
      const end: number = bounds[i + 1];
      if (start >= end) {
        continue; // 去重后的相邻同值边界
      }
      const segment: RichSegment = new RichSegment();
      segment.text = text.substring(start, end);
      for (const range of ranges) {
        // entity 须完整覆盖该片段才生效（嵌套 entity 天然按覆盖关系叠加）
        if (range.start <= start && end <= range.end) {
          RichText.applyType(segment, range, text);
        }
      }
      RichText.appendMerged(segments, segment);
    }
    return segments;
  }

  /**
   * 样式指纹（ForEach 键 / 气泡重建判定用）：文本已在键中（MessageBubbleModel.keySuffix），
   * 此处补样式与链接目标——编辑仅改 entity（如换链接目标）而文本不变时也能触发重建。
   */
  static fingerprint(segments: Array<RichSegment>): string {
    let fp: string = `${segments.length}`;
    for (const segment of segments) {
      let flags: number = 0;
      if (segment.bold) {
        flags += 1;
      }
      if (segment.italic) {
        flags += 2;
      }
      if (segment.underline) {
        flags += 4;
      }
      if (segment.strikethrough) {
        flags += 8;
      }
      if (segment.code) {
        flags += 16;
      }
      if (segment.link) {
        flags += 32;
      }
      fp += `_${flags}:${segment.url.length}`;
    }
    return fp;
  }

  /** entities 数组 → 钳制后的区间列表（非法项丢弃） */
  private static collectRanges(formatted: Record<string, Object>, text: string): Array<EntityRange> {
    const entitiesObj: Object | undefined = formatted[TdField.ENTITIES];
    if (!Array.isArray(entitiesObj)) {
      return [];
    }
    const entities: Array<Object> = entitiesObj as Array<Object>;
    const ranges: Array<EntityRange> = [];
    for (const item of entities) {
      const entity: Record<string, Object> | null = RichText.asRecord(item);
      if (entity === null) {
        continue;
      }
      const offset: number = RichText.readNumber(entity, TdField.OFFSET);
      const length: number = RichText.readNumber(entity, TdField.LENGTH);
      // 钳制：负偏移归零，长度按剩余文本截断；零长度丢弃
      const start: number = Math.max(0, offset);
      const end: number = Math.min(text.length, start + Math.max(0, length));
      if (end <= start) {
        continue;
      }
      const typeObj: Record<string, Object> | null = RichText.asRecord(entity[TdField.TYPE]);
      if (typeObj === null) {
        continue;
      }
      const range: EntityRange = {
        start: start,
        end: end,
        type: RichText.readString(typeObj, TdField.TYPE),
        url: RichText.readString(typeObj, TdField.URL)
      };
      ranges.push(range);
    }
    return ranges;
  }

  /** entity 类型 → 片段样式（未识别类型不施加样式） */
  private static applyType(segment: RichSegment, range: EntityRange, text: string): void {
    switch (range.type) {
      case TdTextEntityType.BOLD:
        segment.bold = true;
        break;
      case TdTextEntityType.ITALIC:
        segment.italic = true;
        break;
      case TdTextEntityType.UNDERLINE:
        segment.underline = true;
        break;
      case TdTextEntityType.STRIKETHROUGH:
        segment.strikethrough = true;
        break;
      case TdTextEntityType.CODE:
      case TdTextEntityType.PRE:
      case TdTextEntityType.PRE_CODE:
        segment.code = true;
        break;
      case TdTextEntityType.TEXT_URL:
        segment.link = true;
        if (range.url.length > 0) {
          segment.url = range.url;
        }
        break;
      case TdTextEntityType.URL:
        segment.link = true;
        segment.url = text.substring(range.start, range.end);
        break;
      case TdTextEntityType.MENTION:
      case TdTextEntityType.HASHTAG:
      case TdTextEntityType.CASHTAG:
      case TdTextEntityType.BOT_COMMAND:
      case TdTextEntityType.EMAIL_ADDRESS:
      case TdTextEntityType.PHONE_NUMBER:
      case TdTextEntityType.MENTION_NAME:
        segment.link = true; // 链接色；点击跳转（打开会话/邮件等）属后续迭代
        break;
      default:
        break; // custom_emoji/spoiler/block_quote 等：普通文本（占位不崩溃）
    }
  }

  /** 相邻同样式片段合并（一个 entity 边界两侧样式相同时收敛为单 Span） */
  private static appendMerged(segments: Array<RichSegment>, segment: RichSegment): void {
    const last: RichSegment | undefined = segments.length > 0 ? segments[segments.length - 1] : undefined;
    if (last !== undefined && RichText.sameStyle(last, segment)) {
      last.text += segment.text;
      return;
    }
    segments.push(segment);
  }

  private static sameStyle(a: RichSegment, b: RichSegment): boolean {
    return a.bold === b.bold && a.italic === b.italic && a.underline === b.underline &&
      a.strikethrough === b.strikethrough && a.code === b.code && a.link === b.link && a.url === b.url;
  }

  private static readNumber(source: Record<string, Object>, field: string): number {
    const value: Object | undefined = source[field];
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }
    return 0;
  }

  private static readString(source: Record<string, Object>, field: string): string {
    const value: Object | undefined = source[field];
    return typeof value === 'string' ? value : '';
  }

  private static asRecord(value: Object | undefined): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }
}

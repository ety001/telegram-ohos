/**
 * 消息内容媒体提取（M3-media）：TDLib message.content → 视图友好的结构化信息。
 *
 * TL 契约（1.8.63 td_api.tl@f06b0bac 逐条核对，schema 版本差异高发区）：
 * - messagePhoto photo:photo video:video caption:formattedText ...：photo 自带 video 字段
 *   （动画贴纸"弹跳"用，1.8.63 引入），纯图片展示忽略；
 * - photo = has_stickers / minithumbnail:minithumbnail / sizes:vector<photoSize>（注意：无 id 字段，
 *   id 是后版 schema 才回加的）；
 * - photoSize = type / photo:file / width / height / progressive_sizes（渐进式 JPEG 前缀字节数组）；
 * - video / document / animation 的缩略图统一为 thumbnail 类型
 *   （format:ThumbnailFormat / width / height / file:file）——不是旧文档里的 photoSize，字段名是 file；
 * - minithumbnail.data 为 base64 的 JPEG（TL bytes → JSON 字符串），Image 可直接拼 data URI 显示；
 * - voiceNote = duration / waveform / mime_type / speech_recognition_result / voice:file。
 *
 * 本文件只做纯数据投影（不改 TDLib 原对象），视图模型与下载状态由消费侧组装。
 * M3-notifications 增补 previewTextOf/contentPlaceholderOf：单行预览提取下沉 core，
 * 会话列表行（ChatUi）与本地通知正文（NotificationService）共用一份。
 */
import { TdField, TdMessageContent, TdType } from './TdConstants';
import { ChatListStore } from './ChatListStore';

/** photoSize 投影（保留原 file 对象引用：FileDownloadStore.trackFile 需要完整 local 状态做种子） */
export class PhotoSizeInfo {
  fileId: number = 0;
  width: number = 0;
  height: number = 0;
  /** TDLib file 原对象（含 local.is_downloading_completed / local.path，可为 null） */
  file: Record<string, Object> | null = null;
}

export class PhotoInfo {
  /** minithumbnail.data（裸 base64，未拼前缀）；空串 = 无缩略图 */
  miniData: string = '';
  /** 选中的展示尺寸（宽 ≤1080 中最大者） */
  selected: PhotoSizeInfo | null = null;
}

export class VideoInfo {
  fileId: number = 0;
  fileName: string = '';
  mimeType: string = '';
  durationSeconds: number = 0;
  width: number = 0;
  height: number = 0;
  miniData: string = '';
  /** thumbnail.file（1.8.63 为 thumbnail 类型，字段名 file；后版才叫 photo） */
  thumbFile: Record<string, Object> | null = null;
  thumbFileId: number = 0;
  thumbWidth: number = 0;
  thumbHeight: number = 0;
  videoFile: Record<string, Object> | null = null;
}

export class DocumentInfo {
  fileId: number = 0;
  fileName: string = '';
  mimeType: string = '';
  sizeBytes: number = 0;
  docFile: Record<string, Object> | null = null;
}

export class VoiceInfo {
  durationSeconds: number = 0;
}

export class AnimationInfo {
  fileName: string = '';
  width: number = 0;
  height: number = 0;
}

/** 回复引用定位（M6-2；message.reply_to → messageReplyToMessage 投影） */
export class ReplyRef {
  chatId: number = 0;
  messageId: number = 0;
  /** 跨会话回复时 origin 可能携带名称/来源（同会话恒 null） */
  origin: Record<string, Object> | null = null;
  /** 跨会话回复时源消息内容预览（同会话恒 null） */
  content: Record<string, Object> | null = null;
}

/** 气泡媒体分支类型（model.mediaKind 取值） */
export class MediaKind {
  static readonly NONE: string = 'none';
  static readonly PHOTO: string = 'photo';
  static readonly VIDEO: string = 'video';
  static readonly DOCUMENT: string = 'document';
  static readonly VOICE: string = 'voice';
  static readonly ANIMATION: string = 'animation';
  static readonly STICKER: string = 'sticker';
  static readonly AUDIO: string = 'audio';
}

export class MessageContent {
  /** 气泡展示上限：超过 1080 宽的 photoSize 不选（TDLib sizes 最大档常见 1280/2560，直接全尺寸拉流量） */
  static readonly PHOTO_MAX_WIDTH: number = 1080;

  /** content['@type'] → 媒体分支；文本/未知类型返回 NONE */
  static mediaKindOf(content: Record<string, Object> | null): string {
    if (content === null) {
      return MediaKind.NONE;
    }
    const typeObj: Object | undefined = content[TdField.TYPE];
    const type: string = typeof typeObj === 'string' ? typeObj : '';
    switch (type) {
      case TdMessageContent.PHOTO:
        return MediaKind.PHOTO;
      case TdMessageContent.VIDEO:
      case TdMessageContent.VIDEO_NOTE:
        return MediaKind.VIDEO;
      case TdMessageContent.DOCUMENT:
        return MediaKind.DOCUMENT;
      case TdMessageContent.VOICE_NOTE:
        return MediaKind.VOICE;
      case TdMessageContent.ANIMATION:
        return MediaKind.ANIMATION;
      case TdMessageContent.STICKER:
        return MediaKind.STICKER;
      case TdMessageContent.AUDIO:
        return MediaKind.AUDIO;
      default:
        return MediaKind.NONE;
    }
  }

  /** messagePhoto → 图片信息（选中尺寸 + minithumbnail）；非 photo 或无可用尺寸返回 null */
  static extractPhoto(content: Record<string, Object>): PhotoInfo | null {
    const photo: Record<string, Object> | null = MessageContent.asRecord(content[TdField.PHOTO]);
    if (photo === null) {
      return null;
    }
    const info: PhotoInfo = new PhotoInfo();
    info.miniData = MessageContent.miniDataOf(photo[TdField.MINITHUMBNAIL]);
    const sizesObj: Object | undefined = photo[TdField.SIZES];
    if (!Array.isArray(sizesObj)) {
      // 无 sizes 数组：只剩 minithumbnail 也可先占位展示
      return info.miniData.length === 0 ? null : info;
    }
    const sizes: Array<Object> = sizesObj as Array<Object>;
    let best: PhotoSizeInfo | null = null;
    let smallest: PhotoSizeInfo | null = null;
    for (const item of sizes) {
      const size: Record<string, Object> | null = MessageContent.asRecord(item);
      if (size === null) {
        continue;
      }
      const file: Record<string, Object> | null = MessageContent.asRecord(size[TdField.PHOTO]);
      const fileId: number = file === null ? 0 : MessageContent.readNumber(file, TdField.ID);
      if (fileId === 0) {
        continue; // 空占位 size（width=0 的 "t" 档）防御跳过
      }
      const candidate: PhotoSizeInfo = new PhotoSizeInfo();
      candidate.fileId = fileId;
      candidate.width = MessageContent.readNumber(size, TdField.WIDTH);
      candidate.height = MessageContent.readNumber(size, TdField.HEIGHT);
      candidate.file = file;
      if (smallest === null || candidate.width < smallest.width) {
        smallest = candidate;
      }
      // 选宽 ≤1080 中最大的一档；全部超宽时回退最小档（保证可显示）
      if (candidate.width <= MessageContent.PHOTO_MAX_WIDTH &&
        (best === null || candidate.width > best.width)) {
        best = candidate;
      }
    }
    info.selected = best !== null ? best : smallest;
    return info;
  }

  /** messageVideo / messageVideoNote → 视频信息；非视频或 file id 缺失返回 null */
  static extractVideo(content: Record<string, Object>): VideoInfo | null {
    const video: Record<string, Object> | null = MessageContent.asRecord(content[TdField.VIDEO]);
    if (video === null) {
      const note: Record<string, Object> | null = MessageContent.asRecord(content[TdField.VIDEO_NOTE]);
      if (note === null) {
        return null;
      }
      return MessageContent.videoInfoOf(note);
    }
    return MessageContent.videoInfoOf(video);
  }

  private static videoInfoOf(video: Record<string, Object>): VideoInfo | null {
    const videoFile: Record<string, Object> | null = MessageContent.asRecord(video[TdField.VIDEO]);
    if (videoFile === null) {
      return null;
    }
    const info: VideoInfo = new VideoInfo();
    info.fileId = MessageContent.readNumber(videoFile, TdField.ID);
    if (info.fileId === 0) {
      return null;
    }
    info.videoFile = videoFile;
    info.fileName = MessageContent.readString(video, TdField.FILE_NAME);
    info.mimeType = MessageContent.readString(video, TdField.MIME_TYPE);
    info.durationSeconds = MessageContent.readNumber(video, TdField.DURATION);
    info.width = MessageContent.readNumber(video, TdField.WIDTH);
    info.height = MessageContent.readNumber(video, TdField.HEIGHT);
    info.miniData = MessageContent.miniDataOf(video[TdField.MINITHUMBNAIL]);
    const thumb: Record<string, Object> | null = MessageContent.asRecord(video[TdField.THUMBNAIL]);
    if (thumb !== null) {
      const thumbFile: Record<string, Object> | null = MessageContent.asRecord(thumb[TdField.FILE]);
      if (thumbFile !== null) {
        info.thumbFile = thumbFile;
        info.thumbFileId = MessageContent.readNumber(thumbFile, TdField.ID);
        info.thumbWidth = MessageContent.readNumber(thumb, TdField.WIDTH);
        info.thumbHeight = MessageContent.readNumber(thumb, TdField.HEIGHT);
      }
    }
    return info;
  }

  /** messageDocument → 文件信息；缺 file 返回 null */
  static extractDocument(content: Record<string, Object>): DocumentInfo | null {
    const document: Record<string, Object> | null = MessageContent.asRecord(content[TdField.DOCUMENT]);
    if (document === null) {
      return null;
    }
    const docFile: Record<string, Object> | null = MessageContent.asRecord(document[TdField.DOCUMENT]);
    if (docFile === null) {
      return null;
    }
    const info: DocumentInfo = new DocumentInfo();
    info.fileId = MessageContent.readNumber(docFile, TdField.ID);
    if (info.fileId === 0) {
      return null;
    }
    info.docFile = docFile;
    info.fileName = MessageContent.readString(document, TdField.FILE_NAME);
    info.mimeType = MessageContent.readString(document, TdField.MIME_TYPE);
    const exact: number = MessageContent.readNumber(docFile, TdField.SIZE);
    const expected: number = MessageContent.readNumber(docFile, TdField.EXPECTED_SIZE);
    info.sizeBytes = exact > 0 ? exact : expected;
    return info;
  }

  /** messageVoiceNote → 时长（无 voice_note 返回 null） */
  static extractVoice(content: Record<string, Object>): VoiceInfo | null {
    const note: Record<string, Object> | null = MessageContent.asRecord(content[TdField.VOICE_NOTE]);
    if (note === null) {
      return null;
    }
    const info: VoiceInfo = new VoiceInfo();
    info.durationSeconds = MessageContent.readNumber(note, TdField.DURATION);
    return info;
  }

  /** messageAnimation → 基本信息（M5 才实装播放，此处供占位展示尺寸） */
  static extractAnimation(content: Record<string, Object>): AnimationInfo | null {
    const animation: Record<string, Object> | null = MessageContent.asRecord(content[TdField.ANIMATION]);
    if (animation === null) {
      return null;
    }
    const info: AnimationInfo = new AnimationInfo();
    info.fileName = MessageContent.readString(animation, TdField.FILE_NAME);
    info.width = MessageContent.readNumber(animation, TdField.WIDTH);
    info.height = MessageContent.readNumber(animation, TdField.HEIGHT);
    return info;
  }

  /** photo/video/document 的 caption 纯文本（formattedText.text；无则空串） */
  static extractCaption(content: Record<string, Object>): string {
    const formatted: Record<string, Object> | null = MessageContent.asRecord(content[TdField.CAPTION]);
    if (formatted === null) {
      return '';
    }
    return MessageContent.readString(formatted, TdField.TEXT);
  }

  /**
   * 消息单行预览（会话列表行 / 本地通知正文共用，M3-notifications 下沉至 core）：
   * messageText → 压空白单行；媒体类型给中文占位文案；未知类型回退 [消息]。
   * 截断由调用方按展示位宽自定（通知 80 字 / 列表行 maxLines+ellipsis）。
   */
  static previewTextOf(message: Record<string, Object>): string {
    const content: Record<string, Object> | null = MessageContent.asRecord(message[TdField.CONTENT]);
    if (content === null) {
      return '';
    }
    const typeObj: Object | undefined = content[TdField.TYPE];
    const type: string = typeof typeObj === 'string' ? typeObj : '';
    if (type === TdMessageContent.TEXT) {
      const formatted: Record<string, Object> | null = MessageContent.asRecord(content[TdField.TEXT]);
      if (formatted === null) {
        return '';
      }
      // 多行文本压成单行预览
      return MessageContent.readString(formatted, TdField.TEXT).replace(/\s+/g, ' ').trim();
    }
    return MessageContent.contentPlaceholderOf(type);
  }

  /** 媒体/特殊内容类型的预览占位文案（未知新类型回退 [消息]） */
  static contentPlaceholderOf(type: string): string {
    switch (type) {
      case TdMessageContent.PHOTO:
        return '[图片]';
      case TdMessageContent.VIDEO:
      case TdMessageContent.VIDEO_NOTE:
        return '[视频]';
      case TdMessageContent.DOCUMENT:
        return '[文件]';
      case TdMessageContent.VOICE_NOTE:
        return '[语音]';
      case TdMessageContent.ANIMATION:
        return '[动画]';
      case TdMessageContent.STICKER:
        return '[贴纸]';
      case TdMessageContent.AUDIO:
        return '[音频]';
      case TdMessageContent.LOCATION:
        return '[位置]';
      case TdMessageContent.CONTACT:
        return '[联系人]';
      case TdMessageContent.POLL:
        return '[投票]';
      case TdMessageContent.CALL:
        return '[通话]';
      default:
        return '[消息]';
    }
  }

  // ---------------- 回复引用（M6-2） ----------------

  /** message.reply_to → ReplyRef；非 messageReplyToMessage（story 回复等）或字段缺失返回 null */
  static replyRefOf(message: Record<string, Object>): ReplyRef | null {
    const replyTo: Record<string, Object> | null = MessageContent.asRecord(message[TdField.REPLY_TO]);
    if (replyTo === null) {
      return null;
    }
    const typeObj: Object | undefined = replyTo[TdField.TYPE];
    if (typeObj !== TdType.MESSAGE_REPLY_TO_MESSAGE) {
      return null;
    }
    const ref: ReplyRef = new ReplyRef();
    ref.chatId = MessageContent.readNumber(replyTo, TdField.CHAT_ID);
    ref.messageId = MessageContent.readNumber(replyTo, TdField.MESSAGE_ID);
    if (ref.messageId === 0) {
      return null;
    }
    ref.origin = MessageContent.asRecord(replyTo[TdField.ORIGIN]);
    ref.content = MessageContent.asRecord(replyTo[TdField.CONTENT]);
    return ref;
  }

  /**
   * 跨会话回复的 origin 显示名：hiddenUser.sender_name > channel/chat 的会话标题 >
   * user（M6-4 UserStore 前不可解析，降级 fallback）。
   */
  static originNameOf(origin: Record<string, Object> | null, fallback: string): string {
    if (origin === null) {
      return fallback;
    }
    const typeObj: Object | undefined = origin[TdField.TYPE];
    const type: string = typeof typeObj === 'string' ? typeObj : '';
    if (type === TdType.MESSAGE_ORIGIN_HIDDEN_USER) {
      const name: string = MessageContent.readString(origin, TdField.SENDER_NAME);
      return name.length > 0 ? name : fallback;
    }
    if (type === TdType.MESSAGE_ORIGIN_CHANNEL || type === TdType.MESSAGE_ORIGIN_CHAT) {
      const title: string = ChatListStore.getInstance().getTitle(MessageContent.readNumber(origin, TdField.CHAT_ID));
      return title.length > 0 ? title : fallback;
    }
    return fallback;
  }

  /** MessageContent 对象（非 message）的单行预览：包装为 message 形状复用 previewTextOf */
  static previewOfContent(content: Record<string, Object> | null): string {
    if (content === null) {
      return '';
    }
    const wrapper: Record<string, Object> = {};
    wrapper[TdField.CONTENT] = content;
    return MessageContent.previewTextOf(wrapper);
  }

  /** 字节数格式化（自写）：B / KB / MB / GB，保留 1 位小数（≥100 整数位足够时省小数） */
  static formatBytes(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes <= 0) {
      return '';
    }
    const UNITS: Array<string> = ['B', 'KB', 'MB', 'GB'];
    let value: number = bytes;
    let unitIndex: number = 0;
    while (value >= 1024 && unitIndex < UNITS.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    const text: string = value >= 100 || unitIndex === 0 ? `${Math.round(value)}` : value.toFixed(1);
    return `${text} ${UNITS[unitIndex]}`;
  }

  /** 秒 → m:ss / h:mm:ss */
  static formatDuration(seconds: number): string {
    if (!Number.isFinite(seconds) || seconds < 0) {
      return '';
    }
    const total: number = Math.round(seconds);
    const hours: number = Math.floor(total / 3600);
    const minutes: number = Math.floor((total % 3600) / 60);
    const secs: number = total % 60;
    const two: string = secs < 10 ? `0${secs}` : `${secs}`;
    if (hours > 0) {
      const shortMinutes: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
      return `${hours}:${shortMinutes}:${two}`;
    }
    return `${minutes}:${two}`;
  }

  private static miniDataOf(mini: Object | undefined): string {
    const record: Record<string, Object> | null = MessageContent.asRecord(mini);
    if (record === null) {
      return '';
    }
    return MessageContent.readString(record, TdField.DATA);
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

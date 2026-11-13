/**
 * TDLib TL 类型常量集中管理（M2 建立，M3 增补消息收发类）。
 * 所有 td_send/td_execute 的 @type 与更新流 @type 一律引用本文件，禁止散落魔法字符串。
 * 注意：对象字面量的键受 ArkTS 限制须为字符串字面量（arkts-identifiers-as-prop-names），
 * 写入侧字面量键与读取侧 TdField 常量保持同名对应。
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
  // 认证引导（1.8.63 td_json_client.h 契约：首次请求前 TDLib 不发送任何 update，
  // 客户端启动后必须先发一个请求解锁 updateAuthorizationState 流）
  static readonly GET_AUTHORIZATION_STATE: string = 'getAuthorizationState';
  // 同步探测（1.8.63 td_api.tl:14694：getOption 对 "version"/"commit_hash" 可同步调用；
  // getVersion 系后版 API，1.8.63 不存在，td_execute 会返回 error 400 Function not found）
  static readonly GET_OPTION: string = 'getOption';
  // 会话列表（1.8.63 schema：getChats/loadChats 无 offset 参数，分页由 loadChats 增量加载）
  static readonly GET_CHATS: string = 'getChats';
  static readonly LOAD_CHATS: string = 'loadChats';
  static readonly GET_CHAT: string = 'getChat';
  // 消息收发（1.8.63 schema：sendMessage 无 message_thread_id/reply_to_message_id 平铺字段，
  // 主题/回复分别是 topic_id:MessageTopic 与 reply_to:InputMessageReplyTo 对象，纯文本发送可整体缺省）
  static readonly SEND_MESSAGE: string = 'sendMessage';
  // 附件发送（1.8.63 schema）
  static readonly SEND_PHOTO: string = 'sendPhoto';
  static readonly SEND_DOCUMENT: string = 'sendDocument';
  // 1.8.63 schema：getChatHistory(chat_id, from_message_id, offset, limit, only_local) 返回 messages
  static readonly GET_CHAT_HISTORY: string = 'getChatHistory';
  static readonly VIEW_MESSAGES: string = 'viewMessages';
  static readonly OPEN_CHAT: string = 'openChat';
  static readonly CLOSE_CHAT: string = 'closeChat';
  static readonly DELETE_MESSAGES: string = 'deleteMessages';
  // 媒体下载（1.8.63 schema：downloadFile(file_id, priority, offset, limit, synchronous) 返回 file，
  // 尚无 suffix 参数——后版 schema 才引入，勿混用）
  static readonly DOWNLOAD_FILE: string = 'downloadFile';
  static readonly CANCEL_DOWNLOAD_FILE: string = 'cancelDownloadFile';
  // 会话操作（M5；结果经 updateChatPosition / updateChatNotificationSettings / 列表移除等更新流驱动）
  // 1.8.63 schema：toggleChatIsPinned(chat_list:ChatList, chat_id:int53, is_pinned:Bool)
  static readonly TOGGLE_CHAT_IS_PINNED: string = 'toggleChatIsPinned';
  // 1.8.63 schema：setChatNotificationSettings(chat_id:int53, notification_settings:chatNotificationSettings)
  static readonly SET_CHAT_NOTIFICATION_SETTINGS: string = 'setChatNotificationSettings';
  // 1.8.63 schema：deleteChat(chat_id:int53)——群聊将同时删除所有成员的会话（can_be_deleted_for_all_users 判定）
  static readonly DELETE_CHAT: string = 'deleteChat';
  // 消息操作（M6-2）
  // 1.8.63 schema：getMessage(chat_id:int53, message_id:int53) = Message（引用条源消息补拉）
  static readonly GET_MESSAGE: string = 'getMessage';
  // 消息操作（M6-3）
  // 1.8.63 schema：editMessageText(chat_id, message_id, reply_markup:ReplyMarkup 可空, input_message_content) = Message
  static readonly EDIT_MESSAGE_TEXT: string = 'editMessageText';
  // 1.8.63 schema：editMessageCaption(chat_id, message_id, reply_markup, caption:formattedText,
  // show_caption_above_media:Bool——必须从原消息 content 透传，否则原上方 caption 被移回下方)
  static readonly EDIT_MESSAGE_CAPTION: string = 'editMessageCaption';
  // 1.8.63 schema：forwardMessages(chat_id, topic_id:MessageTopic 可空, from_chat_id, message_ids,
  // options:messageSendOptions 可空, send_copy:Bool, remove_caption:Bool) = Messages
  static readonly FORWARD_MESSAGES: string = 'forwardMessages';
  // 会话搜索与用户（M6-4）
  // 1.8.63 schema：searchChats(query:string, limit:int32) = Chats——离线搜全部已知会话
  static readonly SEARCH_CHATS: string = 'searchChats';
  // 1.8.63 schema：getUser(user_id:int53) = User
  static readonly GET_USER: string = 'getUser';
  // 会话内搜索（M6-5）
  // 1.8.63 schema：searchChatMessages(chat_id, topic_id:MessageTopic 可空, query, sender_id:MessageSender
  // 可空, from_message_id, offset, limit, filter:SearchMessagesFilter) = FoundChatMessages
  static readonly SEARCH_CHAT_MESSAGES: string = 'searchChatMessages';
  // 语音已听上报（M6-6）
  // 1.8.63 schema：openMessageContent(chat_id:int53, message_id:int53) = Ok——语音播放后标记已听
  static readonly OPEN_MESSAGE_CONTENT: string = 'openMessageContent';
}

export class TdUpdate {
  static readonly AUTHORIZATION_STATE: string = 'updateAuthorizationState';
  static readonly OPTION: string = 'updateOption';
  // 会话列表（TDLib 契约：updateNewChat 保证先于该 chat 出现在 getChats 结果中）
  static readonly NEW_CHAT: string = 'updateNewChat';
  static readonly CHAT_POSITION: string = 'updateChatPosition';
  static readonly CHAT_LAST_MESSAGE: string = 'updateChatLastMessage';
  static readonly CHAT_READ_INBOX: string = 'updateChatReadInbox';
  static readonly CHAT_TITLE: string = 'updateChatTitle';
  static readonly CHAT_PHOTO: string = 'updateChatPhoto';
  // 免打扰设置变更（M3-notifications 复审 HIGH-2；1.8.63 schema：updateChatNotificationSettings
  // 1.8.63 schema（td_api.tl:9884）：{ notification_settings, chat_id:int53 }——chat_id 必填；
  // 全局默认设置变更为 updateScopeNotificationSettings（另一事件类型，本仓库未消费，M5 挂账）
  static readonly CHAT_NOTIFICATION_SETTINGS: string = 'updateChatNotificationSettings';
  // getChats/searchChats 的结果对象（@type=chats，结果与 update 走同一分发入口）
  static readonly CHATS: string = 'chats';
  // getOption(version) 的结果对象（@type=optionValueString，value 字段为版本号字符串）
  static readonly OPTION_VALUE_STRING: string = 'optionValueString';
  // getChat 的结果对象（@type=chat，chats 结果缺项时的补拉响应）
  static readonly CHAT_RESULT: string = 'chat';
  // 消息收发（M3）
  static readonly NEW_MESSAGE: string = 'updateNewMessage';
  static readonly MESSAGE_SEND_SUCCEEDED: string = 'updateMessageSendSucceeded';
  static readonly MESSAGE_SEND_FAILED: string = 'updateMessageSendFailed';
  static readonly MESSAGE_CONTENT: string = 'updateMessageContent';
  static readonly DELETE_MESSAGES: string = 'updateDeleteMessages';
  // 消息被编辑（M6-3；1.8.63 schema：{chat_id, message_id, edit_date, reply_markup}——
  // edit_date 经此更新下发，与 updateMessageContent 分离，漏注册会导致「已编辑」标记永不出现）
  static readonly MESSAGE_EDITED: string = 'updateMessageEdited';
  static readonly CHAT_READ_OUTBOX: string = 'updateChatReadOutbox';
  // getChatHistory 的结果对象（@type=messages，含完整 message 数组；与 update 走同一分发入口）
  static readonly MESSAGES: string = 'messages';
  // 云端草稿变更（M6-1；1.8.63 schema：{ chat_id, draft_message:draftMessage, positions }——
  // 客户端无写草稿 API（saveDraft 已移除），仅其他端同步来的草稿经此更新；本地草稿走 DraftStore）
  static readonly CHAT_DRAFT_MESSAGE: string = 'updateChatDraftMessage';
  // 用户在线状态（M6-4；updateUserStatus{user_id, status:UserStatus}；user 结果对象 @type=user）
  static readonly USER_STATUS: string = 'updateUserStatus';
  static readonly USER: string = 'user';
  // 媒体下载进度/完成通知（updateFile.file：含 local.path / is_downloading_* / downloaded_size）
  static readonly UPDATE_FILE: string = 'updateFile';
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

/** ChatList 子类型（chat_position.list['@type']） */
export class TdChatList {
  static readonly MAIN: string = 'chatListMain';
}

/** MessageContent 子类型（last_message.content['@type']，会话列表预览提取用） */
export class TdMessageContent {
  static readonly TEXT: string = 'messageText';
  static readonly PHOTO: string = 'messagePhoto';
  static readonly VIDEO: string = 'messageVideo';
  static readonly VIDEO_NOTE: string = 'messageVideoNote';
  static readonly DOCUMENT: string = 'messageDocument';
  static readonly VOICE_NOTE: string = 'messageVoiceNote';
  static readonly ANIMATION: string = 'messageAnimation';
  static readonly STICKER: string = 'messageSticker';
  static readonly AUDIO: string = 'messageAudio';
  static readonly LOCATION: string = 'messageLocation';
  static readonly CONTACT: string = 'messageContact';
  static readonly POLL: string = 'messagePoll';
  static readonly CALL: string = 'messageCall';
}

/** MessageSendingState 子类型（message.sending_state['@type']；字段缺省/null = 已发送） */
export class TdSendingState {
  static readonly PENDING: string = 'messageSendingStatePending';
  static readonly FAILED: string = 'messageSendingStateFailed';
}

/** InputMessageContent 子类型与配套包装类型名（sendMessage 入参用） */
export class TdInputMessage {
  static readonly INPUT_MESSAGE_TEXT: string = 'inputMessageText';
  static readonly FORMATTED_TEXT: string = 'formattedText';
  // 文本发送简写
  static readonly TEXT: string = 'inputMessageText';
  // 附件发送（1.8.63 schema：sendMessage 的 input_message_content 用）
  static readonly PHOTO: string = 'inputMessagePhoto';
  static readonly DOCUMENT: string = 'inputMessageDocument';
}

/** MessageSource 子类型（viewMessages.source 用；1.8.63 为对象类型，非旧版 message_source 字符串） */
export class TdMessageSource {
  static readonly CHAT_HISTORY: string = 'messageSourceChatHistory';
}

/**
 * 消息域 @type 子类型常量（M6-2 起；reply/origin 类对象的判别与构造）。
 * 1.8.63 schema 逐条核对：
 * - sendMessage.reply_to 用 inputMessageReplyToMessage（仅 message_id 必填）；
 * - message.reply_to 为 messageReplyToMessage{chat_id,message_id,quote,origin,content}——
 *   同会话回复 origin/content 恒 null（schema 注释 may be null for messages from the same chat）；
 * - MessageOrigin 子类型按可用名称字段解析，messageOriginUser 需 UserStore（M6-4 前降级）。
 */
export class TdType {
  static readonly INPUT_MESSAGE_REPLY_TO_MESSAGE: string = 'inputMessageReplyToMessage';
  static readonly MESSAGE_REPLY_TO_MESSAGE: string = 'messageReplyToMessage';
  static readonly MESSAGE_ORIGIN_USER: string = 'messageOriginUser';
  static readonly MESSAGE_ORIGIN_HIDDEN_USER: string = 'messageOriginHiddenUser';
  static readonly MESSAGE_ORIGIN_CHANNEL: string = 'messageOriginChannel';
  static readonly MESSAGE_ORIGIN_CHAT: string = 'messageOriginChat';
  // 会话类型与用户状态（M6-4；chat.type / updateUserStatus.status 判别）
  static readonly CHAT_TYPE_PRIVATE: string = 'chatTypePrivate';
  static readonly USER_STATUS_ONLINE: string = 'userStatusOnline';
  static readonly USER_STATUS_OFFLINE: string = 'userStatusOffline';
  // 消息发送者（UI 打磨：message.sender_id:messageSenderUser{user_id}，群聊昵称/分组键）
  static readonly MESSAGE_SENDER_USER: string = 'messageSenderUser';
  static readonly MESSAGE_SENDER_CHAT: string = 'messageSenderChat';
  // 会话内搜索（M6-5；foundChatMessages 结果对象 / 过滤器空集）
  static readonly FOUND_CHAT_MESSAGES: string = 'foundChatMessages';
  static readonly SEARCH_MESSAGES_FILTER_EMPTY: string = 'searchMessagesFilterEmpty';
  // 贴纸格式（M6-7；sticker.format:StickerFormat 判别——webp 静态可直渲，tgs/webm 动效挂 M7）
  static readonly STICKER_FORMAT_WEBP: string = 'stickerFormatWebp';
  static readonly STICKER_FORMAT_TGS: string = 'stickerFormatTgs';
  static readonly STICKER_FORMAT_WEBM: string = 'stickerFormatWebm';
}

/**
 * TextEntityType 子类型（formattedText.entities[].type['@type']，M5 富文本渲染）。
 * 1.8.63 td_api.tl（commit f06b0bac）逐条核对；未列出的类型（custom_emoji/spoiler/block_quote/
 * media_timestamp/date_time）M5 暂按普通文本渲染（贴纸面板/剧透遮罩等属后续迭代）。
 */
export class TdTextEntityType {
  static readonly BOLD: string = 'textEntityTypeBold';
  static readonly ITALIC: string = 'textEntityTypeItalic';
  static readonly UNDERLINE: string = 'textEntityTypeUnderline';
  static readonly STRIKETHROUGH: string = 'textEntityTypeStrikethrough';
  static readonly CODE: string = 'textEntityTypeCode';
  static readonly PRE: string = 'textEntityTypePre';
  static readonly PRE_CODE: string = 'textEntityTypePreCode';
  /** 带显式 url 字段的可点击链接（url 为 HTTP 或 tg:// 深链） */
  static readonly TEXT_URL: string = 'textEntityTypeTextUrl';
  /** 原文即 URL 的链接（点击目标 = 该段文本本身） */
  static readonly URL: string = 'textEntityTypeUrl';
  // 以下类型渲染为链接色（mention 等），点击跳转属后续迭代
  static readonly MENTION: string = 'textEntityTypeMention';
  static readonly HASHTAG: string = 'textEntityTypeHashtag';
  static readonly CASHTAG: string = 'textEntityTypeCashtag';
  static readonly BOT_COMMAND: string = 'textEntityTypeBotCommand';
  static readonly EMAIL_ADDRESS: string = 'textEntityTypeEmailAddress';
  static readonly PHONE_NUMBER: string = 'textEntityTypePhoneNumber';
  static readonly MENTION_NAME: string = 'textEntityTypeMentionName';
}

/** TDLib 通用字段名 */
export class TdField {
  static readonly TYPE: string = '@type';
  static readonly EXTRA: string = '@extra';
  static readonly CLIENT_ID: string = '@client_id';
  static readonly MESSAGE: string = 'message';
  static readonly VERSION: string = 'version';
  static readonly VALUE: string = 'value';
  static readonly NAME: string = 'name';
  static readonly ERROR: string = 'error';
  // chat / update 通用字段
  static readonly ID: string = 'id';
  static readonly CHAT_ID: string = 'chat_id';
  static readonly TITLE: string = 'title';
  static readonly PHOTO: string = 'photo';
  static readonly CHAT: string = 'chat';
  static readonly CHAT_LIST: string = 'chat_list';
  static readonly LIST: string = 'list';
  static readonly POSITION: string = 'position';
  static readonly POSITIONS: string = 'positions';
  static readonly ORDER: string = 'order';
  static readonly IS_PINNED: string = 'is_pinned';
  static readonly UNREAD_COUNT: string = 'unread_count';
  static readonly CHAT_IDS: string = 'chat_ids';
  static readonly LAST_MESSAGE: string = 'last_message';
  static readonly DATE: string = 'date';
  static readonly CONTENT: string = 'content';
  static readonly TEXT: string = 'text';
  static readonly LIMIT: string = 'limit';
  // 富文本 entities（M5；formattedText.entities，offset/length 均按 UTF-16 code unit 计）
  // 注：OFFSET 复用下方 downloadFile 请求的既有同名常量（字段名同为 'offset'）
  static readonly ENTITIES: string = 'entities';
  static readonly LENGTH: string = 'length';
  static readonly URL: string = 'url';
  // message / 消息请求通用字段（M3）
  static readonly MESSAGE_ID: string = 'message_id';
  static readonly MESSAGE_IDS: string = 'message_ids';
  // 回复引用（M6-2；message.reply_to / messageReplyToMessage 字段）+ 发送者（UI 打磨）
  static readonly REPLY_TO: string = 'reply_to';
  static readonly SENDER_ID: string = 'sender_id';
  static readonly ORIGIN: string = 'origin';
  static readonly SENDER_NAME: string = 'sender_name';
  // 编辑与转发来源（M6-3；message.edit_date / message.forward_info:messageForwardInfo）
  static readonly EDIT_DATE: string = 'edit_date';
  static readonly FORWARD_INFO: string = 'forward_info';
  // editMessageCaption 入参（M6-3；show_caption_above_media 从原 content 透传）
  static readonly SHOW_CAPTION_ABOVE_MEDIA: string = 'show_caption_above_media';
  // 头像与用户（M6-4；chatPhotoInfo.small / user 对象字段；minithumbnail.data 复用既有 DATA 常量）
  static readonly SMALL: string = 'small';
  static readonly STATUS: string = 'status';
  static readonly USER_ID: string = 'user_id';
  // 语音/音频（M6-6；voiceNote/audio/is_listened 字段）
  static readonly WAVEFORM: string = 'waveform';
  static readonly IS_LISTENED: string = 'is_listened';
  static readonly PERFORMER: string = 'performer';
  // title 复用既有 chat.title 的 TITLE 常量（同名同值）
  // 贴纸（M6-7；sticker{format,emoji,sticker:file} / thumbnail.file）
  static readonly FORMAT: string = 'format';
  static readonly EMOJI: string = 'emoji';
  static readonly FIRST_NAME: string = 'first_name';
  static readonly LAST_NAME: string = 'last_name';
  static readonly EXPIRES: string = 'expires';
  // userStatusOffline.was_online:int32（最后在线时间；注意与 Online.expires 字段名不同）
  static readonly WAS_ONLINE: string = 'was_online';
  static readonly NEW_CONTENT: string = 'new_content';
  static readonly OLD_MESSAGE_ID: string = 'old_message_id';
  static readonly SENDING_STATE: string = 'sending_state';
  static readonly IS_OUTGOING: string = 'is_outgoing';
  static readonly CAN_RETRY: string = 'can_retry';
  static readonly FROM_MESSAGE_ID: string = 'from_message_id';
  static readonly ONLY_LOCAL: string = 'only_local';
  static readonly FORCE_READ: string = 'force_read';
  static readonly SOURCE: string = 'source';
  static readonly INPUT_MESSAGE_CONTENT: string = 'input_message_content';
  static readonly REVOKE: string = 'revoke';
  static readonly FROM_CACHE: string = 'from_cache';
  static readonly LAST_READ_OUTBOX_MESSAGE_ID: string = 'last_read_outbox_message_id';
  // 通知免打扰判定（M3-notifications；chat.notification_settings.mute_for，1.8.63 schema：
  // chatNotificationSettings.mute_for:int32，>0 即静音中，TDLib 周期性刷新该值）
  static readonly NOTIFICATION_SETTINGS: string = 'notification_settings';
  static readonly MUTE_FOR: string = 'mute_for';
  // 云端草稿（M6-1；chat.draft_message:draftMessage，draft_message 可为 null；行预览提取
  // draft_message.input_message_text.text——1.8.63 schema 字段名即 input_message_text）
  static readonly DRAFT_MESSAGE: string = 'draft_message';
  // draftMessage 内容字段名（1.8.63：input_message_text:InputMessageContent，注意与
  // sendMessage 入参字段 input_message_content 是两个不同字段名）
  static readonly DRAFT_INPUT_CONTENT: string = 'input_message_text';
  // setChatNotificationSettings 入参：置 false 才能按会话粒度覆盖 mute_for（M5 会话菜单）
  static readonly USE_DEFAULT_MUTE_FOR: string = 'use_default_mute_for';
  // 媒体内容与文件（M3-media；字段名以 1.8.63 td_api.tl 为准）
  // 注意：messagePhoto.photo 复用上方 chat.photo 的 PHOTO 常量（同名同值）
  static readonly VIDEO: string = 'video';
  static readonly VIDEO_NOTE: string = 'video_note';
  static readonly DOCUMENT: string = 'document';
  static readonly VOICE_NOTE: string = 'voice_note';
  static readonly VOICE: string = 'voice';
  static readonly AUDIO: string = 'audio';
  static readonly ANIMATION: string = 'animation';
  static readonly STICKER: string = 'sticker';
  static readonly CAPTION: string = 'caption';
  static readonly SIZES: string = 'sizes';
  static readonly MINITHUMBNAIL: string = 'minithumbnail';
  static readonly THUMBNAIL: string = 'thumbnail';
  static readonly DATA: string = 'data';
  static readonly WIDTH: string = 'width';
  static readonly HEIGHT: string = 'height';
  static readonly DURATION: string = 'duration';
  static readonly FILE_NAME: string = 'file_name';
  static readonly MIME_TYPE: string = 'mime_type';
  static readonly SUPPORTS_STREAMING: string = 'supports_streaming';
  // file / localFile / downloadFile 请求字段
  static readonly FILE: string = 'file';
  static readonly LOCAL: string = 'local';
  static readonly PATH: string = 'path';
  static readonly SIZE: string = 'size';
  static readonly EXPECTED_SIZE: string = 'expected_size';
  static readonly IS_DOWNLOADING_ACTIVE: string = 'is_downloading_active';
  static readonly IS_DOWNLOADING_COMPLETED: string = 'is_downloading_completed';
  static readonly DOWNLOADED_SIZE: string = 'downloaded_size';
  static readonly PRIORITY: string = 'priority';
  static readonly OFFSET: string = 'offset';
  static readonly SYNCHRONOUS: string = 'synchronous';
}
